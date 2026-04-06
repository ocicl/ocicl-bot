;;; ocicl-bot.lisp -- Automated ingestion of new CL projects into ocicl
;;;
;;; Monitors quicklisp-projects issues for new package requests,
;;; validates them, and creates ocicl repos with the standard structure.
;;; Uses cl-workflow for durable workflow execution.
;;;
;;; Container layout:
;;;   /config/         -- app-key.pem, cursor (mounted from ~/.local/etc/ocicl-bot/)
;;;   /data/           -- ocicl-bot.db (mounted from ~/.local/share/ocicl-bot/)
;;;   /ocicl-admin/    -- git checkouts (mounted from ~/ocicl-admin/)
;;;
;;; Usage:
;;;   (asdf:load-system :ocicl-bot)
;;;   (ocicl-bot:run)

(defpackage #:ocicl-bot
  (:use #:cl #:cl-workflow)
  (:export #:run #:wait-and-save-cursor #:*engine*))

(in-package #:ocicl-bot)

;;; ─── Logging ───────────────────────────────────────────────────────────────

(setf llog:*logger* (llog:make-logger :name "ocicl-bot" :level llog:+info+))

;;; ─── Paths (overridable via env vars) ──────────────────────────────────────

(defparameter *ocicl-admin-home*
  (or (uiop:getenv "OCICL_ADMIN_HOME") "/ocicl-admin/"))

(defparameter *config-dir*
  (or (uiop:getenv "OCICL_BOT_CONFIG") "/config/"))

(defparameter *data-dir*
  (or (uiop:getenv "OCICL_BOT_DATA") "/data/"))

;;; ─── GitHub App Authentication ──────────────────────────────────────────────

(defparameter *github-app-id* "3293488")
(defparameter *github-installation-id* "121833864")
(defparameter *github-app-key-path*
  (merge-pathnames "app-key.pem" (pathname *config-dir*)))

(defvar *github-token* nil)
(defvar *github-token-expires* 0)

(defun make-github-app-jwt ()
  "Create a JWT signed with the GitHub App private key."
  (multiple-value-bind (n e d) (cl-x509:load-rsa-key-pair *github-app-key-path*)
    (let* ((now (- (get-universal-time) 2208988800))  ; Unix epoch
           (key (ironclad:make-private-key :rsa :n n :e e :d d))
           (claims `(("iss" . ,*github-app-id*)
                     ("iat" . ,(- now 60))
                     ("exp" . ,(+ now 540)))))  ; 9 minutes (max 10)
      (jose/jwt:encode :rs256 key claims))))

(defun get-installation-token ()
  "Get a fresh installation access token from GitHub, or return cached one."
  (when (< (get-universal-time) *github-token-expires*)
    (return-from get-installation-token *github-token*))
  (let* ((jwt (make-github-app-jwt))
         (response (drakma:http-request
                    (format nil "https://api.github.com/app/installations/~A/access_tokens"
                            *github-installation-id*)
                    :method :post
                    :additional-headers `(("Authorization" . ,(format nil "Bearer ~A" jwt))
                                          ("Accept" . "application/vnd.github+json"))
                    :content-type "application/json"
                    :want-stream nil))
         (body (if (typep response '(simple-array (unsigned-byte 8) (*)))
                   (flexi-streams:octets-to-string response :external-format :utf-8)
                   response))
         (parsed (let ((cl-json:*json-identifier-name-to-lisp* #'identity)
                       (cl-json:*identifier-name-to-key* #'identity))
                   (cl-json:decode-json-from-string body)))
         (token (cdr (assoc "token" parsed :test #'string=))))
    (unless token
      (error "Failed to get installation token: ~A" body))
    (llog:info "GitHub installation token acquired")
    (setf *github-token* token)
    (setf *github-token-expires* (+ (get-universal-time) 3000))
    token))

(defun ensure-github-auth ()
  "Set up cl-github-v3 auth using the GitHub App installation token."
  (let ((token (get-installation-token)))
    (setf github:*username* "x-access-token"
          github:*password* token)))

(defun gh-api (endpoint &key (method :get) body parameters)
  "Call the GitHub REST API via cl-github-v3."
  (ensure-github-auth)
  (github:api-command endpoint :method method :body body :parameters parameters))

;;; ─── LLM Provider ──────────────────────────────────────────────────────────

(defvar *llm-provider* nil)

(defun ensure-llm-provider ()
  "Initialize the Gemini LLM provider if needed."
  (unless *llm-provider*
    (let ((api-key (or (uiop:getenv "GEMINI_API_KEY")
                       (let ((key-file (merge-pathnames "gemini-api-key" (pathname *config-dir*))))
                         (when (probe-file key-file)
                           (string-trim '(#\Newline #\Space #\Return)
                                        (uiop:read-file-string key-file))))
                       (error "GEMINI_API_KEY not set and no key file in config dir"))))
      (setf *llm-provider*
            (make-instance 'completions:gemini-completer
                           :api-key api-key
                           :model "gemini-2.5-flash"))))
  *llm-provider*)

;;; ─── Git helpers (via legit) ───────────────────────────────────────────────

(defun authed-clone-url (url)
  "Inject the installation token into an HTTPS GitHub URL for auth."
  (let ((token (get-installation-token)))
    (if (search "https://github.com" url)
        (format nil "https://x-access-token:~A@~A"
                token (subseq url (length "https://")))
        url)))

(defun git-clone-shallow (url target-dir)
  "Shallow clone a repo into TARGET-DIR."
  (legit:clone (authed-clone-url url) target-dir :depth 1))

(defun git-clone-repo (url target-dir)
  "Clone a repo into TARGET-DIR."
  (legit:clone (authed-clone-url url) target-dir))

(defun run-git-in (dir &rest args)
  "Run git with ARGS in directory DIR."
  (uiop:run-program (cons "git" args)
                     :directory (pathname dir)
                     :output '(:string :stripped t)
                     :error-output '(:string :stripped t)))

(defun git-add-commit-push (repo-dir message)
  "Stage all, commit as ocicl-bot, push."
  ;; Set bot identity
  (run-git-in repo-dir "config" "user.name" "ocicl-bot[bot]")
  (run-git-in repo-dir "config" "user.email"
              (format nil "~A+ocicl-bot[bot]@users.noreply.github.com" *github-app-id*))
  ;; Set authed remote URL
  (let* ((token (get-installation-token))
         (old-url (run-git-in repo-dir "remote" "get-url" "origin")))
    (when (search "github.com" old-url)
      (multiple-value-bind (match groups)
          (cl-ppcre:scan-to-strings "github\\.com[/:](.+?)(?:\\.git)?$" old-url)
        (when match
          (run-git-in repo-dir "remote" "set-url" "origin"
                      (format nil "https://x-access-token:~A@github.com/~A.git"
                              token (aref groups 0)))))))
  ;; Stage, commit, push
  (run-git-in repo-dir "add" "-A")
  (handler-case
      (progn
        (run-git-in repo-dir "diff" "--cached" "--quiet")
        ;; No changes
        nil)
    (error ()
      ;; There are changes
      (run-git-in repo-dir "commit" "-m" message)
      ;; Ensure we're on main branch (empty repos may not have one)
      (handler-case (run-git-in repo-dir "branch" "-M" "main")
        (error () nil))
      (run-git-in repo-dir "push" "-u" "origin" "main"))))

(defun clean-admin-dir (admin-dir name lc-name)
  "Remove stale checkout directories (handles case variants)."
  (let ((dir1 (merge-pathnames (format nil "~A/" lc-name) admin-dir))
        (dir2 (merge-pathnames (format nil "~A/" name) admin-dir)))
    (when (uiop:directory-exists-p dir1)
      (uiop:delete-directory-tree dir1 :validate t))
    (when (and (not (equal (namestring dir1) (namestring dir2)))
               (uiop:directory-exists-p dir2))
      (uiop:delete-directory-tree dir2 :validate t))))

;;; ─── Reserved / blocked names ───────────────────────────────────────────────

(defparameter *reserved-system-names*
  '("asdf" "uiop" "sb-ext" "sb-thread" "sb-posix" "sb-bsd-sockets" "sb-sys"
    "sb-alien" "sb-debug" "sb-gray" "sb-mop" "sb-pcl" "sb-cltl2" "sb-introspect"
    "sb-concurrency" "sb-sprof" "sb-cover" "sb-rotate-byte" "sb-sequence"
    "cl" "common-lisp" "keyword" "common-lisp-user" "cl-user")
  "System names that must never be registered -- they collide with CL builtins.")

(defparameter *skip-project-names*
  '("qlot" "quicklisp" "quicklisp-client" "quicklisp-slime-helper"
    "quickdist" "quickdocs" "quickproject")
  "Project names to skip -- qlot/quicklisp ecosystem tools not relevant to ocicl.")

;;; ─── Activities ────────────────────────────────────────────────────────────

(defactivity fetch-new-ql-issues ((since-issue-number integer))
  "Fetch open issues from quicklisp/quicklisp-projects with number > SINCE."
  :retry-policy (:max-attempts 3 :initial-interval 5 :backoff-coefficient 2.0)
  :timeout 60
  (let ((page 1)
        (issues '()))
    (loop
      (let ((batch (gh-api (format nil "/repos/quicklisp/quicklisp-projects/issues")
                           :parameters (list :state "open"
                                             :per-page "100"
                                             :sort "created"
                                             :direction "asc"
                                             :page (princ-to-string page)))))
        (when (null batch) (return))
        (dolist (issue batch)
          (let ((num (getf issue :number)))
            (when (and num (> num since-issue-number))
              (push (list :number num
                          :title (or (getf issue :title) "")
                          :body (or (getf issue :body) ""))
                    issues))))
        (when (< (length batch) 100) (return))
        (incf page)))
    (let ((result (nreverse issues)))
      (llog:info (format nil "Fetched ~D new issues (since #~D)" (length result) since-issue-number))
      result)))

(defactivity parse-issue-with-llm ((issue-number integer) (title string) (body string))
  "Use Gemini via cl-completions to extract project name and git URL from an issue."
  :retry-policy (:max-attempts 2 :initial-interval 5)
  :timeout 120
  (let* ((prompt (format nil "Extract the project information from this GitHub issue requesting a new Common Lisp project be added to quicklisp.

Issue #~D: ~A

~A

Respond with EXACTLY this format (no markdown, no explanation):
NAME: <project-name>
URL: <git-clone-url ending in .git>
DESCRIPTION: <one-line description>
SYSTEMS: <space-separated list of likely ASDF system names, best guess from the project name>
CONTENT_FLAG: OK or REVIEW

Set CONTENT_FLAG to REVIEW if the project name, description, or stated purpose:
- Contains crude, vulgar, or offensive language
- Relates to political or religious topics
- Could be libelous (disparages specific people or organizations)
- Promotes illegal activity
- Contains hate speech or discriminatory content
Otherwise set it to OK.

If this is not a request to add a new project (e.g., it's a rename request, removal request, or bug report), respond with exactly:
SKIP: <reason>"
                         issue-number title body))
         (response (progn
                     (llog:debug (format nil "Parsing issue #~D with LLM" issue-number))
                     (completions:get-completion (ensure-llm-provider) prompt))))
    (cond
      ((search "SKIP:" response)
       (list :skip t :reason (string-trim " " (subseq response (+ (search "SKIP:" response) 5)))))
      ((and (search "NAME:" response) (search "URL:" response))
       (flet ((extract (key)
                (let ((start (search key response)))
                  (when start
                    (let* ((val-start (+ start (length key)))
                           (val-end (or (position #\Newline response :start val-start)
                                        (length response))))
                      (string-trim " " (subseq response val-start val-end)))))))
         (let ((name (extract "NAME:"))
               (url (extract "URL:"))
               (desc (extract "DESCRIPTION:"))
               (systems (extract "SYSTEMS:"))
               (flag (extract "CONTENT_FLAG:")))
           (if (and name url (plusp (length name)) (plusp (length url)))
               (list :name name :url url :description desc :systems systems
                     :content-flag (if (and flag (search "REVIEW" (string-upcase flag)))
                                       :review
                                       :ok))
               nil))))
      (t nil))))

(defactivity check-ocicl-status ((name string))
  "Check the state of a system in ocicl. Returns a keyword:
   :PUBLISHED, :REPO-OK, :REPO-BROKEN, :REPO-EMPTY, or :NONE."
  :retry-policy (:max-attempts 2 :initial-interval 3)
  :timeout 30
  ;; Check if published as OCI artifact
  (handler-case
      (progn
        (gh-api (format nil "/orgs/ocicl/packages/container/~A" name))
        (return-from check-ocicl-status :published))
    (error () nil))
  ;; Check if repo exists
  (let ((repo-info (handler-case (gh-api (format nil "/repos/ocicl/~A" name))
                     (error () nil))))
    (unless repo-info
      (return-from check-ocicl-status :none))
    ;; Repo exists -- check size
    (let ((size (or (getf repo-info :size) 0)))
      (when (zerop size)
        (return-from check-ocicl-status :repo-empty))))
  ;; Has content -- check README.org systems field
  (handler-case
      (let* ((content-info (gh-api (format nil "/repos/ocicl/~A/contents/README.org" name)))
             (encoded (getf content-info :content))
             (decoded (if encoded
                         (handler-case
                             (sb-ext:octets-to-string
                              (cl-base64:base64-string-to-usb8-array
                               (remove #\Newline encoded))
                              :external-format :utf-8)
                           (error () ""))
                         ""))
             (systems-line (find-if (lambda (l) (search "| systems" l))
                                    (uiop:split-string decoded :separator '(#\Newline)))))
        (if (and systems-line
                 (let* ((bar-pos (search "| " systems-line
                                         :start2 (+ (search "systems" systems-line) 7)))
                        (value (when bar-pos
                                 (string-trim (list #\Space (code-char 124) #\Tab)
                                              (subseq systems-line (+ bar-pos 2))))))
                   (and value (plusp (length value)))))
            :repo-ok
            :repo-broken))
    (error () :repo-broken)))

(defactivity fetch-ocicl-systems-list ()
  "Download the current all-ocicl-systems.txt. Returns a list of system name strings."
  :retry-policy (:max-attempts 3 :initial-interval 5)
  :timeout 30
  (let* ((content-info (gh-api "/repos/ocicl/request-system-additions-here/contents/all-ocicl-systems.txt"))
         (encoded (getf content-info :content))
         (decoded (sb-ext:octets-to-string
                   (cl-base64:base64-string-to-usb8-array (remove #\Newline encoded))
                   :external-format :utf-8)))
    (remove-if (lambda (s) (zerop (length s)))
               (uiop:split-string decoded :separator '(#\Newline)))))

(defactivity check-system-name-collisions ((discovered-systems list) (existing-systems list))
  "Check if any discovered system names collide with existing ocicl systems.
   Returns a list of colliding names, or NIL if clean."
  :retry-policy (:max-attempts 1)
  :timeout 10
  (let ((existing-set (make-hash-table :test 'equal)))
    (dolist (s existing-systems) (setf (gethash s existing-set) t))
    (remove-if-not (lambda (s) (gethash s existing-set)) discovered-systems)))

(defactivity check-reserved-names ((discovered-systems list))
  "Check if any discovered system names are reserved CL builtins.
   Returns a list of reserved names found, or NIL if clean."
  :retry-policy (:max-attempts 1)
  :timeout 10
  (remove-if-not (lambda (s) (member s *reserved-system-names* :test #'string-equal))
                 discovered-systems))

(defactivity validate-upstream-repo ((url string))
  "Validate the upstream git repo. Returns a plist of warnings/info:
   :reachable T/NIL, :is-fork T/NIL, :has-license T/NIL, :license-file STRING/NIL"
  :retry-policy (:max-attempts 2 :initial-interval 5)
  :timeout 60
  (let ((result (list :reachable nil :is-fork nil :has-license nil :license-file nil)))
    ;; Check reachability by extracting owner/repo from GitHub URL
    (let ((gh-match (multiple-value-list
                     (cl-ppcre:scan-to-strings
                      "github\\.com[/:]([^/]+)/([^/.]+)" url))))
      (when (second gh-match)
        (let* ((groups (second gh-match))
               (owner (aref groups 0))
               (repo (aref groups 1)))
          (handler-case
              (let ((info (gh-api (format nil "/repos/~A/~A" owner repo))))
                (setf (getf result :reachable) t)
                ;; Fork check
                (setf (getf result :is-fork) (eq t (getf info :fork)))
                ;; License check (GitHub detects license automatically)
                (let ((license (getf info :license)))
                  (when license
                    (let ((key (getf license :key)))
                      (when (and key (not (string= key "other")))
                        (setf (getf result :has-license) t)
                        (setf (getf result :license-file) key))))))
            (error ()
              ;; Not reachable via GitHub API -- might be GitLab/Codeberg
              ;; Try a simple git ls-remote
              (handler-case
                  (progn
                    (uiop:run-program (list "env" "GIT_TERMINAL_PROMPT=0" "git" "ls-remote" "--exit-code" url "HEAD")
                                      :output nil :error-output nil)
                    (setf (getf result :reachable) t))
                (error () nil)))))))
    ;; For non-GitHub URLs, just check reachability
    (unless (getf result :reachable)
      (handler-case
          (progn
            (uiop:run-program (list "env" "GIT_TERMINAL_PROMPT=0" "git" "ls-remote" "--exit-code" url "HEAD")
                              :output nil :error-output nil)
            (setf (getf result :reachable) t))
        (error () nil)))
    result))

(defun extract-defsystem-names (content)
  "Extract defsystem names from an .asd file's content string."
  (let ((systems '())
        (pos 0))
    (loop
      (let ((found (search "defsystem" content :start2 pos :test #'char-equal)))
        (unless found (return systems))
        (let ((after (position-if-not
                      (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return)))
                      content :start (+ found 9))))
          (when after
            (let ((ch (char content after)))
              (cond
                ;; Quoted name: (defsystem "foo")
                ((char= ch #\")
                 (let ((end (position #\" content :start (1+ after))))
                   (when end
                     (let ((sys-name (string-downcase (subseq content (1+ after) end))))
                       (when (plusp (length sys-name))
                         (unless (or (search "-test" sys-name)
                                     (search "/test" sys-name)
                                     (search "-tests" sys-name)
                                     (search "/tests" sys-name))
                           (pushnew sys-name systems :test #'string=)))))))
                ;; Bare or prefixed
                (t
                 (let* ((name-start (position-if-not
                                     (lambda (c) (member c '(#\# #\:)))
                                     content :start after))
                        (name-end (when name-start
                                    (position-if
                                     (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\) #\")))
                                     content :start name-start))))
                   (when (and name-start name-end (> name-end name-start))
                     (let ((sys-name (string-downcase (subseq content name-start name-end))))
                       (unless (or (search "-test" sys-name)
                                   (search "/test" sys-name)
                                   (search "-tests" sys-name)
                                   (search "/tests" sys-name))
                         (pushnew sys-name systems :test #'string=))))))))))
        (setf pos (1+ found))))))

(defactivity clone-and-find-systems ((name string) (url string))
  "Clone the upstream repo and discover ASDF system names."
  :retry-policy (:max-attempts 2 :initial-interval 5)
  :timeout 120
  (let ((tmpdir (format nil "/tmp/ocicl-ingest-~A-~A" name (get-universal-time))))
    (unwind-protect
         (progn
           (git-clone-shallow url tmpdir)
           (let* ((asd-files (directory
                              (merge-pathnames "**/*.asd" (pathname (format nil "~A/" tmpdir)))))
                  (systems '()))
             (dolist (asd-file asd-files)
               (ignore-errors
                 (let ((content (uiop:read-file-string asd-file)))
                   (dolist (s (extract-defsystem-names content))
                     (pushnew s systems :test #'string=)))))
             (unless systems
               (error "No ASDF systems found in ~A" url))
             (list :systems (sort systems #'string<))))
      (ignore-errors
        (uiop:delete-directory-tree (pathname (format nil "~A/" tmpdir)) :validate t)))))

(defun populate-ocicl-repo-dir (repo-dir lc-name url description systems)
  "Write the standard ocicl repo files into REPO-DIR."
  ;; Remove everything except .git
  (dolist (entry (append (uiop:directory-files repo-dir)
                         (uiop:subdirectories repo-dir)))
    (let ((name (enough-namestring entry repo-dir)))
      (unless (or (string= name ".git/")
                  (search ".git" (namestring entry)))
        (if (uiop:directory-pathname-p entry)
            (uiop:delete-directory-tree entry :validate t)
            (delete-file entry)))))
  ;; .gitignore
  (with-open-file (s (merge-pathnames ".gitignore" repo-dir)
                     :direction :output :if-exists :supersede)
    (write-line "*~" s))
  ;; GitHub Actions workflow
  (let ((wf-dir (merge-pathnames ".github/workflows/" repo-dir)))
    (ensure-directories-exist wf-dir)
    (with-open-file (s (merge-pathnames "main.yml" wf-dir)
                       :direction :output :if-exists :supersede)
      (format s "on:
  push:
  workflow_dispatch:
  schedule:
    # Check for updates every 6 hours
    - cron: '0 */6 * * *'

jobs:
  ocicl_job:
    permissions:
      issues: write
      packages: write
      contents: write
    runs-on: ubuntu-latest
    name: Test and publish package
    timeout-minutes: 40
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Check for upstream updates
        id: update-check
        uses: ocicl/ocicl-action/update-check@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}

      - id: build-and-publish
        if: steps.update-check.outputs.updated == 'true'
        uses: ocicl/ocicl-action@main
        with:
          gpg_signing_key: ${{ secrets.GPG_SIGNING_KEY }}
          gpg_public_key: ${{ secrets.GPG_PUBLIC_KEY }}
          dockerhub_password: ${{ secrets.DOCKERHUB_PASSWORD }}
          llm_api_key: ${{ secrets.LLM_API_KEY }}
")))
  ;; LICENSE
  (with-open-file (s (merge-pathnames "LICENSE" repo-dir)
                     :direction :output :if-exists :supersede)
    (format s "--------------------------------------------------------------------------------
This license pertains to the files within this repository, and does
not apply to software that is merely referenced by, but not
incorporated into, this repository.
--------------------------------------------------------------------------------

MIT License

Copyright (c) ~A ocicl hackers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the \"Software\"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
" (nth-value 5 (get-decoded-time))))
  ;; README.org
  (let ((git-url (if (search ".git" url) url (format nil "~A.git" url))))
    (with-open-file (s (merge-pathnames "README.org" repo-dir)
                       :direction :output :if-exists :supersede)
      (format s "* ~A~%~%~A~%~%|---------+~A|~%| source  | git:~A~A|~%| commit  | 0000000~A|~%| systems | ~A~A|~%|---------+~A|~%"
              lc-name
              (or description "")
              (make-string 60 :initial-element #\-)
              git-url (make-string (max 0 (- 58 (length git-url) 4)) :initial-element #\Space)
              (make-string 52 :initial-element #\Space)
              systems (make-string (max 0 (- 58 (length systems))) :initial-element #\Space)
              (make-string 60 :initial-element #\-)))))

(defactivity fix-ocicl-repo ((name string) (url string) (description string)
                              (systems string))
  "Fix an existing ocicl repo: write full standard structure and push."
  :retry-policy (:max-attempts 2 :initial-interval 10)
  :timeout 180
  (let* ((admin-dir *ocicl-admin-home*)
         (lc-name (string-downcase name))
         (repo-dir (format nil "~A/~A/" admin-dir lc-name)))
    (ensure-directories-exist (pathname (format nil "~A/" admin-dir)))
    (clean-admin-dir admin-dir name lc-name)
    (git-clone-repo (format nil "https://github.com/ocicl/~A.git" lc-name) repo-dir)
    (populate-ocicl-repo-dir (pathname repo-dir) lc-name url description systems)
    (git-add-commit-push repo-dir "Fix repo: add standard structure")
    (llog:info (format nil "Fixed ocicl/~A" lc-name))
    (format nil "Fixed ocicl/~A" lc-name)))

(defactivity create-ocicl-repo ((name string) (url string) (description string)
                                 (systems string))
  "Create the ocicl repo on GitHub with the standard structure."
  :retry-policy (:max-attempts 2 :initial-interval 10)
  :timeout 180
  (let* ((admin-dir *ocicl-admin-home*)
         (lc-name (string-downcase name))
         (repo-dir (format nil "~A/~A/" admin-dir lc-name)))
    (ensure-directories-exist (pathname (format nil "~A/" admin-dir)))
    (clean-admin-dir admin-dir name lc-name)
    ;; Create repo on GitHub via API
    (handler-case
        (gh-api "/orgs/ocicl/repos" :method :post
                :body (list :name lc-name :public t))
      (error () nil))  ; may already exist
    (git-clone-repo (format nil "https://github.com/ocicl/~A.git" lc-name) repo-dir)
    (populate-ocicl-repo-dir (pathname repo-dir) lc-name url description systems)
    (git-add-commit-push repo-dir (format nil "Add ~A" lc-name))
    (llog:info (format nil "Created ocicl/~A" lc-name))
    (format nil "Created ocicl/~A" lc-name)))

(defactivity update-systems-list ((systems-to-add list))
  "Add new system names to all-ocicl-systems.txt."
  :retry-policy (:max-attempts 2 :initial-interval 5)
  :timeout 120
  (let ((repo-dir (format nil "/tmp/ocicl-systems-list-~A/" (get-universal-time))))
    (unwind-protect
         (progn
           (git-clone-repo "https://github.com/ocicl/request-system-additions-here.git" repo-dir)
           (let ((list-file (merge-pathnames "all-ocicl-systems.txt" (pathname repo-dir))))
             ;; Append new systems
             (with-open-file (s list-file :direction :output :if-exists :append)
               (dolist (sys systems-to-add)
                 (format s "~A~%" sys)))
             ;; Sort and deduplicate in-place
             (let* ((lines (uiop:read-file-lines list-file))
                    (sorted (remove-duplicates (sort lines #'string<) :test #'string=)))
               (with-open-file (s list-file :direction :output :if-exists :supersede)
                 (dolist (line sorted)
                   (when (plusp (length line))
                     (format s "~A~%" line))))))
           (git-add-commit-push repo-dir "Add new systems"))
      (ignore-errors
        (uiop:delete-directory-tree (pathname repo-dir) :validate t)))))

(defactivity save-cursor-activity ((issue-number integer))
  "Persist the cursor to disk after processing an issue."
  :retry-policy (:max-attempts 1)
  :timeout 5
  (write-cursor issue-number)
  issue-number)

(defactivity log-result ((issue-number integer) (name string) (status string) (detail string))
  "Log the processing result for an issue."
  :retry-policy (:max-attempts 1)
  :timeout 10
  (cond
    ((string= status "FAILED")
     (llog:error (format nil "~A: ~A" status detail) :issue issue-number :project name))
    ((or (string= status "REJECTED") (string= status "WARNING") (string= status "NEEDS_REVIEW"))
     (llog:warn (format nil "~A: ~A" status detail) :issue issue-number :project name))
    (t
     (llog:info (format nil "~A: ~A" status detail) :issue issue-number :project name)))
  t)

;;; ─── Workflow ──────────────────────────────────────────────────────────────

(defworkflow ingest-quicklisp-requests ((since-issue-number integer))
  "Process new quicklisp-projects issues since SINCE-ISSUE-NUMBER.
   For each issue: parse with LLM, validate, check ocicl, clone+validate, create repo."
  (let ((issues (execute-activity 'fetch-new-ql-issues
                  :input (list since-issue-number)))
        (existing-systems (execute-activity 'fetch-ocicl-systems-list :input nil))
        (created-systems '())
        (seen-projects (make-hash-table :test 'equal))  ; detect duplicate issues
        (highest-issue 0))

    (setf (workflow-state :total-issues) (length issues))
    (setf (workflow-state :processed) 0)

    (dolist (issue issues)
      (let ((num (getf issue :number))
            (title (getf issue :title))
            (body (getf issue :body)))

        (when (> num highest-issue)
          (setf highest-issue num))

        (setf (workflow-state :current-issue) num)

        ;; Fast path: if title is "Please add X" and X is already published, skip LLM
        (let ((quick-name (let ((pos (search "add " (or title "") :test #'char-equal)))
                            (when pos
                              (string-downcase (string-trim " " (subseq title (+ pos 4))))))))
          (when (and quick-name
                     (plusp (length quick-name))
                     (member quick-name existing-systems :test #'string-equal))
            (execute-activity 'log-result
              :input (list num quick-name "ALREADY_EXISTS" "Package already published (fast path)"))
            (incf (workflow-state :processed) 1)
            (execute-activity 'save-cursor-activity :input (list num))
            (go next-issue)))

        ;; Step 1: Parse with LLM
        (let* ((parsed (execute-activity 'parse-issue-with-llm
                         :input (list num title (or body ""))))
               (pname (when parsed (string-downcase (or (getf parsed :name) ""))))
               (purl  (when parsed (getf parsed :url)))
               (desc  (or (when parsed (getf parsed :description)) "")))
          (cond
            ((null parsed)
             (execute-activity 'log-result
               :input (list num "?" "SKIPPED" "Could not parse issue")))

            ((getf parsed :skip)
             (execute-activity 'log-result
               :input (list num "?" "SKIPPED" (getf parsed :reason))))

            ((or (null pname) (zerop (length pname)) (null purl) (zerop (length purl)))
             (execute-activity 'log-result
               :input (list num "?" "SKIPPED" "Missing name or URL")))

            ;; Skip quicklisp/qlot ecosystem projects
            ((member pname *skip-project-names* :test #'string-equal)
             (execute-activity 'log-result
               :input (list num pname "SKIPPED" "Quicklisp/qlot ecosystem project")))

            ;; Duplicate issue detection (same project in this batch)
            ((gethash pname seen-projects)
             (execute-activity 'log-result
               :input (list num pname "SKIPPED"
                            (format nil "Duplicate of issue #~A" (gethash pname seen-projects)))))

            ;; Content flag check
            ((eq (getf parsed :content-flag) :review)
             (execute-activity 'log-result
               :input (list num pname "NEEDS_REVIEW"
                            "Flagged for manual review (content policy)")))

            (t
             (setf (gethash pname seen-projects) num)

             ;; Step 2: Check ocicl status (fast path: check local list first, saves API calls)
             (let ((status (if (member pname existing-systems :test #'string-equal)
                               :published
                               (execute-activity 'check-ocicl-status
                                 :input (list pname)))))
               (cond
                 ((eq status :published)
                  (execute-activity 'log-result
                    :input (list num pname "ALREADY_EXISTS" "Package already published")))

                 ((eq status :repo-ok)
                  (execute-activity 'log-result
                    :input (list num pname "REPO_OK" "Repo exists with valid README.org")))

                 ((or (eq status :none) (eq status :repo-empty) (eq status :repo-broken))
                  ;; Step 3: Validate upstream repo (only for new/broken, saves API calls)
                  (let ((validation (execute-activity 'validate-upstream-repo
                                      :input (list purl))))
                    (cond
                      ((not (getf validation :reachable))
                       (execute-activity 'log-result
                         :input (list num pname "REJECTED" "Upstream repo is unreachable")))
                      ((getf validation :is-fork)
                       (execute-activity 'log-result
                         :input (list num pname "REJECTED"
                                      "Repo is a fork -- use the canonical upstream instead")))
                      (t
                       (unless (getf validation :has-license)
                         (execute-activity 'log-result
                           :input (list num pname "WARNING" "No license detected")))
                       ;; Step 4: Clone and discover systems
                       (handler-case
                             (let* ((discovered (execute-activity 'clone-and-find-systems
                                                  :input (list pname purl)))
                                    (systems (getf discovered :systems))
                                    (systems-str (format nil "~{~A~^ ~}" systems)))

                               ;; Step 5: Check for reserved names
                               (let ((reserved (execute-activity 'check-reserved-names
                                                 :input (list systems))))
                                 (when reserved
                                   (execute-activity 'log-result
                                     :input (list num pname "REJECTED"
                                                  (format nil "Reserved system names: ~{~A~^, ~}" reserved)))
                                   (throw 'skip-issue nil)))

                               ;; Step 6: Check for system name collisions
                               (let ((collisions (execute-activity 'check-system-name-collisions
                                                   :input (list systems existing-systems))))
                                 (when collisions
                                   (execute-activity 'log-result
                                     :input (list num pname "REJECTED"
                                                  (format nil "System names already in ocicl: ~{~A~^, ~}"
                                                          collisions)))
                                   (throw 'skip-issue nil)))

                               ;; Step 7: Create or fix the repo
                               (cond
                                 ((eq status :none)
                                  (execute-activity 'create-ocicl-repo
                                    :input (list pname purl desc systems-str))
                                  (execute-activity 'log-result
                                    :input (list num pname "CREATED"
                                                 (format nil "Systems: ~A" systems-str))))

                                 (t
                                  (execute-activity 'fix-ocicl-repo
                                    :input (list pname purl desc systems-str))
                                  (execute-activity 'log-result
                                    :input (list num pname "FIXED"
                                                 (format nil "Systems: ~A" systems-str)))))

                               ;; Track new systems
                               (dolist (s systems)
                                 (push s created-systems)
                                 (push s existing-systems)))

                           (activity-failure (e)
                             (execute-activity 'log-result
                               :input (list num (or pname "?") "FAILED"
                                            (format nil "~A"
                                                    (activity-failure-last-error e))))))))))))))))

        (incf (workflow-state :processed) 1)
        (execute-activity 'save-cursor-activity :input (list (getf issue :number)))
        next-issue)

    ;; Update all-ocicl-systems.txt with all new systems at once
    (when created-systems
      (execute-activity 'update-systems-list :input (list created-systems)))

    ;; Return summary
    (list :issues-processed (length issues)
          :repos-created (length created-systems)
          :highest-issue highest-issue
          :new-systems created-systems)))

;;; ─── Query Handlers ────────────────────────────────────────────────────────

(defquery ingest-quicklisp-requests progress ()
  "How far along is the ingest run?"
  (list :total (workflow-state :total-issues)
        :processed (workflow-state :processed)
        :current-issue (workflow-state :current-issue)))

;;; ─── Cursor ────────────────────────────────────────────────────────────────

(defun cursor-path ()
  (merge-pathnames "cursor" (pathname *config-dir*)))

(defun read-cursor ()
  "Read the last processed issue number from the cursor file.
   If no cursor exists, estimates a starting point from the latest
   quicklisp-projects issue number minus a buffer of 20."
  (handler-case
      (let ((text (string-trim '(#\Newline #\Space #\Return)
                               (uiop:read-file-string (cursor-path)))))
        (when (plusp (length text))
          (return-from read-cursor (parse-integer text))))
    (error () nil))
  ;; No cursor -- find the oldest unhandled open issue
  (llog:info "No cursor file found, scanning for oldest unhandled issue...")
  (handler-case
      (block found
        (let ((page 1))
          (loop
            (let ((issues (gh-api "/repos/quicklisp/quicklisp-projects/issues"
                                  :parameters (list :state "open"
                                                    :per-page "100"
                                                    :sort "created"
                                                    :direction "asc"
                                                    :page (princ-to-string page)))))
              (when (null issues) (return-from found 0))
              (dolist (issue issues)
                (let* ((num (getf issue :number))
                       (title (or (getf issue :title) ""))
                       (name (let ((pos (search "add " title :test #'char-equal)))
                               (when pos
                                 (string-downcase
                                  (string-trim " " (subseq title (+ pos 4)))))))
                       (status (when (and name (plusp (length name)))
                                 (handler-case
                                     (progn
                                       (gh-api (format nil "/orgs/ocicl/packages/container/~A" name))
                                       :published)
                                   (error () :not-found)))))
                  (when (eq status :not-found)
                    (llog:info (format nil "First unhandled issue: #~D (~A)" num name))
                    (return-from found (max 0 (1- num))))))
              (when (< (length issues) 100) (return-from found 0))
              (incf page)))))
    (error (e)
      (llog:error (format nil "Error bootstrapping cursor: ~A" e))
      0)))

(defun write-cursor (issue-number)
  "Update the cursor file with the new highest issue number."
  (with-open-file (s (cursor-path) :direction :output :if-exists :supersede)
    (format s "~D~%" issue-number)))

;;; ─── Runner ────────────────────────────────────────────────────────────────

(defvar *engine* nil)

(defun db-path ()
  (namestring (merge-pathnames "ocicl-bot.db" (pathname *data-dir*))))

(defun run (&key since)
  "Run the ingest workflow. Reads the cursor file for the starting issue
   number unless SINCE is provided. If a previous run is still RUNNING
   in the DB, resumes it instead of starting a new one."
  (when *engine*
    (ignore-errors (stop-engine *engine*)))
  (ensure-directories-exist (db-path))
  (setf *engine* (make-engine :db-path (db-path)))
  ;; Check if make-engine already resumed a RUNNING workflow
  (let ((contexts (cl-workflow::workflow-engine-contexts *engine*)))
    (when (plusp (hash-table-count contexts))
      (llog:info "Resuming previous run from DB")
      (return-from run :resumed)))
  ;; No running workflow -- start a new one
  (let* ((since-issue (or since (read-cursor)))
         (run-id (start-workflow *engine* 'ingest-quicklisp-requests
                                 :input (list since-issue))))
    (llog:info (format nil "Processing issues after #~D (run: ~A)" since-issue run-id))
    run-id))

(defun wait-and-save-cursor ()
  "Block until the current workflow completes, then update the cursor."
  (loop
    (sleep 5)
    (let ((contexts (cl-workflow::workflow-engine-contexts *engine*)))
      (when (zerop (hash-table-count contexts))
        ;; All workflows finished -- find the result
        (let* ((runs (cl-workflow::db-list-workflow-runs
                      (cl-workflow::workflow-engine-db *engine*) :limit 1))
               (run-id (when runs (first (first runs))))
               (run (when run-id
                      (cl-workflow::db-get-workflow-run
                       (cl-workflow::workflow-engine-db *engine*) run-id)))
               (result (when run (getf run :result))))
          (let ((status (when run (getf run :status))))
            (cond
              ((and result (equal status "COMPLETED"))
               (let ((highest (getf result :highest-issue)))
                 (when (and highest (plusp highest))
                   (write-cursor highest)
                   (llog:info (format nil "Cursor updated to #~D" highest))))
               (llog:info (format nil "Workflow completed: ~D issues, ~D created"
                                  (or (getf result :issues-processed) 0)
                                  (or (getf result :repos-created) 0))))
              ((equal status "FAILED")
               (llog:error (format nil "Workflow FAILED: ~A"
                                   (or (when run (getf run :error-message)) "unknown error"))))
              (t
               (llog:warn (format nil "Workflow ended with status: ~A" status)))))
          (return))))))
