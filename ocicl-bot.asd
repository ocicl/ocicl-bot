;;; ocicl-bot.asd
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green

(asdf:defsystem #:ocicl-bot
  :description "Automated ingestion of new Common Lisp projects into ocicl."
  :author      "Anthony Green"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on (:cl-workflow
               :legit
               :cl-github-v3
               :cl-x509
               :jose
               :cl-base64
               :cl-ppcre
               :cl-json
               :drakma
               :flexi-streams)
  :components ((:file "ocicl-bot")))
