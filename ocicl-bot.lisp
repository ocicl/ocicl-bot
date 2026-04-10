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
  (:export #:run #:wait-for-completion #:*engine*))

(in-package #:ocicl-bot)

;;; ─── Logging ───────────────────────────────────────────────────────────────

(setf llog:*logger* (llog:make-logger :name "ocicl-bot" :level llog:+info+))

(defvar *engine* nil "The cl-workflow engine instance.")

;;; ─── Paths (overridable via env vars) ──────────────────────────────────────

(defparameter *ocicl-admin-home*
  (or (uiop:getenv "OCICL_ADMIN_HOME") "/ocicl-admin/"))

(defparameter *config-dir*
  (or (uiop:getenv "OCICL_BOT_CONFIG") "/config/"))

(defparameter *data-dir*
  (or (uiop:getenv "OCICL_BOT_DATA") "/data/"))

;;; ─── Seen issues tracking ──────────────────────────────────────────────────

(defvar *seen-issues* (make-hash-table :test 'eql))

(defun seen-issues-path ()
  (merge-pathnames "seen-issues.txt" (pathname *data-dir*)))

(defun load-seen-issues ()
  "Load previously seen issue numbers from disk."
  (clrhash *seen-issues*)
  (handler-case
      (dolist (line (uiop:read-file-lines (seen-issues-path)))
        (let ((num (ignore-errors (parse-integer (string-trim " " line)))))
          (when num (setf (gethash num *seen-issues*) t))))
    (error () nil))
  (llog:info (format nil "Loaded ~D seen issues" (hash-table-count *seen-issues*))))

(defun mark-issue-seen (issue-number)
  "Mark an issue as seen and persist to disk."
  (unless (gethash issue-number *seen-issues*)
    (setf (gethash issue-number *seen-issues*) t)
    (with-open-file (s (seen-issues-path)
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create)
      (format s "~D~%" issue-number))))

(defun issue-seen-p (issue-number)
  (gethash issue-number *seen-issues*))

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
  (multiple-value-bind (stdout stderr exit-code)
      (uiop:run-program (cons "git" args)
                         :directory (pathname dir)
                         :output '(:string :stripped t)
                         :error-output '(:string :stripped t)
                         :ignore-error-status t)
    (unless (zerop exit-code)
      (error "Executing git command~%  (git ~{~A~^ ~})~%failed with exit code ~D. Git reported:~%  ~A"
             args exit-code (or stderr stdout "")))
    stdout))

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
  :retry-policy (:max-attempts 3 :initial-interval 30 :backoff-coefficient 2.0)
  :timeout 300
  (let* ((admin-dir *ocicl-admin-home*)
         (lc-name (string-downcase name))
         (repo-dir (format nil "~A/~A/" admin-dir lc-name)))
    (ensure-directories-exist (pathname (format nil "~A/" admin-dir)))
    (clean-admin-dir admin-dir name lc-name)
    ;; Create repo on GitHub via API
    (handler-case
        (gh-api "/orgs/ocicl/repos" :method :post
                :body (list :name lc-name :public t))
      (cl-github::api-error (e)
        (unless (= (cl-github::error-http-status e) 422)  ; 422 = already exists
          (error e))))
    (sleep 15)  ; give GitHub time to propagate the new repo
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

(defactivity mark-issue-seen-activity ((issue-number integer))
  "Mark an issue as processed."
  :retry-policy (:max-attempts 1)
  :timeout 5
  (mark-issue-seen issue-number))

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

;;; ─── Scanner Activities ─────────────────────────────────────────────────────

(defactivity fetch-issue-page ((page integer))
  "Fetch one page of open issues from quicklisp-projects, newest first."
  :retry-policy (:max-attempts 3 :initial-interval 5 :backoff-coefficient 2.0)
  :timeout 30
  (gh-api "/repos/quicklisp/quicklisp-projects/issues"
          :parameters (list :state "open"
                            :per-page "100"
                            :sort "created"
                            :direction "desc"
                            :page (princ-to-string page))))

(defun extract-name-from-title (title)
  "Extract project name from 'Please add X' title. Returns lowercase name or NIL."
  (let ((pos (search "add " (or title "") :test #'char-equal)))
    (when pos
      (let ((name (string-downcase (string-trim " " (subseq title (+ pos 4))))))
        (when (plusp (length name)) name)))))

(defactivity enqueue-build ((issue-number integer) (title string) (body string))
  "Start a build-ocicl-package workflow for this issue."
  :retry-policy (:max-attempts 1)
  :timeout 10
  (let ((wf-id (format nil "build-issue-~D" issue-number)))
    (start-workflow *engine* 'build-ocicl-package
                    :workflow-id wf-id
                    :input (list issue-number title body))
    (llog:info (format nil "Enqueued build for issue #~D: ~A" issue-number title))
    wf-id))

;;; ─── Scanner Workflow ──────────────────────────────────────────────────────

(defworkflow scan-quicklisp-issues ()
  "Scan quicklisp-projects issues newest-first, enqueue builds for unknown projects.
   Stops after 10 consecutive already-known projects."
  (let ((systems (execute-activity 'fetch-ocicl-systems-list :input nil))
        (consecutive-known 0)
        (stop-after 10)
        (skipped 0)
        (enqueued 0))
    (setf (workflow-state :phase) :scanning)
    (block scan-done
      (loop for page from 1
            do (let ((batch (execute-activity 'fetch-issue-page :input (list page))))
                 (when (null batch)
                   (return-from scan-done))
                 (dolist (issue batch)
                   (let* ((num (getf issue :number))
                          (title (or (getf issue :title) ""))
                          (body (or (getf issue :body) ""))
                          (quick-name (extract-name-from-title title)))
                     (setf (workflow-state :current-issue) num)
                     (cond
                       ;; Already processed this issue before
                       ((issue-seen-p num)
                        (incf consecutive-known)
                        (incf skipped))
                       ;; Known project -- count toward stop threshold
                       ((and quick-name
                             (member quick-name systems :test #'string-equal))
                        (mark-issue-seen num)
                        (incf consecutive-known)
                        (incf skipped)
                        (when (>= consecutive-known stop-after)
                          (llog:info (format nil "Stopping: ~D consecutive known (skipped ~D total)"
                                            consecutive-known skipped))
                          (return-from scan-done)))
                       ;; Skip quicklisp/qlot ecosystem
                       ((and quick-name
                             (member quick-name *skip-project-names* :test #'string-equal))
                        (mark-issue-seen num)
                        (incf skipped)
                        (setf consecutive-known 0))
                       ;; Title matches "Please add X" but X not in systems list -- enqueue
                       (quick-name
                        (llog:info (format nil "Skipped ~D known projects" skipped))
                        (setf consecutive-known 0)
                        (setf skipped 0)
                        (execute-activity 'enqueue-build
                          :input (list num title body))
                        (incf enqueued))
                       ;; Can't parse title (rename, update, bug report, etc.) -- skip
                       (t
                        (mark-issue-seen num)
                        (incf skipped)
                        (incf consecutive-known)))))
                 (when (< (length batch) 100)
                   (return-from scan-done)))))
    (setf (workflow-state :phase) :done)
    (llog:info (format nil "Scan complete: enqueued ~D builds" enqueued))
    (list :enqueued enqueued)))

;;; ─── Builder Workflow ──────────────────────────────────────────────────────

(defworkflow build-ocicl-package ((issue-number integer) (title string) (body string))
  "Process a single quicklisp-projects issue: parse, validate, create ocicl repo."
  (setf (workflow-state :phase) :parsing)

  ;; Step 1: Parse with LLM
  (let* ((parsed (execute-activity 'parse-issue-with-llm
                   :input (list issue-number title body)))
         (pname (when parsed (string-downcase (or (getf parsed :name) ""))))
         (purl  (when parsed (getf parsed :url)))
         (desc  (or (when parsed (getf parsed :description)) "")))

    ;; Early exits -- mark issue seen so we don't re-process intentional skips
    (when (null parsed)
      (execute-activity 'mark-issue-seen-activity :input (list issue-number))
      (return-from build-ocicl-package
        (execute-activity 'log-result
          :input (list issue-number "?" "SKIPPED" "Could not parse issue"))))
    (when (getf parsed :skip)
      (execute-activity 'mark-issue-seen-activity :input (list issue-number))
      (return-from build-ocicl-package
        (execute-activity 'log-result
          :input (list issue-number "?" "SKIPPED" (getf parsed :reason)))))
    (when (or (zerop (length pname)) (null purl) (zerop (length purl)))
      (execute-activity 'mark-issue-seen-activity :input (list issue-number))
      (return-from build-ocicl-package
        (execute-activity 'log-result
          :input (list issue-number "?" "SKIPPED" "Missing name or URL"))))
    (when (member pname *skip-project-names* :test #'string-equal)
      (execute-activity 'mark-issue-seen-activity :input (list issue-number))
      (return-from build-ocicl-package
        (execute-activity 'log-result
          :input (list issue-number pname "SKIPPED" "Quicklisp/qlot ecosystem"))))
    (when (eq (getf parsed :content-flag) :review)
      (execute-activity 'mark-issue-seen-activity :input (list issue-number))
      (return-from build-ocicl-package
        (execute-activity 'log-result
          :input (list issue-number pname "NEEDS_REVIEW" "Content policy flag"))))

    ;; Step 2: Check ocicl status (local list first, then API)
    (setf (workflow-state :phase) :checking)
    (let* ((ocicl-systems (execute-activity 'fetch-ocicl-systems-list :input nil))
           (status (if (member pname ocicl-systems :test #'string-equal)
                       :published
                       (execute-activity 'check-ocicl-status :input (list pname)))))
      (when (or (eq status :published) (eq status :repo-ok))
        (execute-activity 'mark-issue-seen-activity :input (list issue-number))
        (return-from build-ocicl-package
          (execute-activity 'log-result
            :input (list issue-number pname "EXISTS" "Already in ocicl"))))

      ;; Step 3: Validate upstream
      (setf (workflow-state :phase) :validating)
      (let ((validation (execute-activity 'validate-upstream-repo :input (list purl))))
        (when (not (getf validation :reachable))
          (execute-activity 'mark-issue-seen-activity :input (list issue-number))
          (return-from build-ocicl-package
            (execute-activity 'log-result
              :input (list issue-number pname "REJECTED" "Upstream unreachable"))))
        (when (getf validation :is-fork)
          (execute-activity 'mark-issue-seen-activity :input (list issue-number))
          (return-from build-ocicl-package
            (execute-activity 'log-result
              :input (list issue-number pname "REJECTED" "Repo is a fork"))))
        (unless (getf validation :has-license)
          (execute-activity 'log-result
            :input (list issue-number pname "WARNING" "No license detected"))))

      ;; Step 4: Clone and discover systems
      (setf (workflow-state :phase) :cloning)
      (let* ((discovered (execute-activity 'clone-and-find-systems :input (list pname purl)))
             (systems (getf discovered :systems))
             (systems-str (format nil "~{~A~^ ~}" systems)))

        ;; Step 5: Check for reserved/colliding names
        (let ((reserved (execute-activity 'check-reserved-names :input (list systems))))
          (when reserved
            (execute-activity 'mark-issue-seen-activity :input (list issue-number))
            (return-from build-ocicl-package
              (execute-activity 'log-result
                :input (list issue-number pname "REJECTED"
                             (format nil "Reserved names: ~{~A~^, ~}" reserved))))))
        (let ((collisions (execute-activity 'check-system-name-collisions
                            :input (list systems ocicl-systems))))
          (when collisions
            (execute-activity 'mark-issue-seen-activity :input (list issue-number))
            (return-from build-ocicl-package
              (execute-activity 'log-result
                :input (list issue-number pname "REJECTED"
                             (format nil "Names already in ocicl: ~{~A~^, ~}" collisions))))))

        ;; Step 6: Create or fix
        (setf (workflow-state :phase) :creating)
        (cond
          ((or (eq status :none) (eq status :repo-empty))
           (execute-activity 'create-ocicl-repo :input (list pname purl desc systems-str))
           (execute-activity 'log-result
             :input (list issue-number pname "CREATED" (format nil "Systems: ~A" systems-str))))
          (t
           (execute-activity 'fix-ocicl-repo :input (list pname purl desc systems-str))
           (execute-activity 'log-result
             :input (list issue-number pname "FIXED" (format nil "Systems: ~A" systems-str)))))

        ;; Step 7: Update systems list
        (execute-activity 'update-systems-list :input (list systems))
        ;; Mark seen only after all work succeeds
        (execute-activity 'mark-issue-seen-activity :input (list issue-number))
        (setf (workflow-state :phase) :done)))))

;;; ─── Query Handlers ────────────────────────────────────────────────────────

(defquery scan-quicklisp-issues progress ()
  (list :phase (workflow-state :phase)
        :current-issue (workflow-state :current-issue)))

(defquery build-ocicl-package progress ()
  (list :phase (workflow-state :phase)))

;;; ─── Runner ────────────────────────────────────────────────────────────────

(defun db-path ()
  (namestring (merge-pathnames "ocicl-bot.db" (pathname *data-dir*))))

(defun run ()
  "Start the scanner workflow. Builder workflows are enqueued automatically."
  (when *engine*
    (ignore-errors (stop-engine *engine*)))
  (ensure-directories-exist (db-path))
  (load-seen-issues)
  (setf *engine* (make-engine :db-path (db-path)))
  ;; If make-engine resumed RUNNING workflows, let them drain first
  (let ((contexts (cl-workflow::workflow-engine-contexts *engine*)))
    (when (plusp (hash-table-count contexts))
      (llog:info (format nil "Resumed ~D running workflow(s) from DB"
                         (hash-table-count contexts)))
      (loop while (plusp (hash-table-count
                          (cl-workflow::workflow-engine-contexts *engine*)))
            do (sleep 2))))
  ;; Start the scanner
  (let ((run-id (start-workflow *engine* 'scan-quicklisp-issues
                                :input nil)))
    (llog:info (format nil "Started scanner (run: ~A)" run-id))
    run-id))

(defun wait-for-completion ()
  "Block until all workflows (scanner + builders) complete."
  (loop
    (sleep 5)
    (let ((contexts (cl-workflow::workflow-engine-contexts *engine*)))
      (when (zerop (hash-table-count contexts))
        ;; Check for any failed workflows
        (let ((failed (cl-workflow::db-list-workflow-runs
                       (cl-workflow::workflow-engine-db *engine*))))
          (dolist (run failed)
            (destructuring-bind (run-id wid wtype status started closed) run
              (declare (ignore wid wtype started closed))
              (when (string= status "FAILED")
                (let ((info (cl-workflow::db-get-workflow-run
                             (cl-workflow::workflow-engine-db *engine*) run-id)))
                  (llog:error (format nil "FAILED ~A: ~A"
                                     run-id (or (getf info :error-message) "?"))))))))
        (llog:info "All workflows complete")
        (return)))))
