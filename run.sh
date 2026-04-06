#!/bin/sh
set -e

echo "ocicl-bot starting at $(date)"

exec sbcl --noinform --non-interactive \
  --eval '(asdf:load-system :ocicl-bot)' \
  --eval '(ocicl-bot:run)' \
  --eval '(ocicl-bot:wait-for-completion)' \
  --eval '(cl-workflow:stop-engine ocicl-bot:*engine*)' \
  --eval '(format t "~&ocicl-bot finished at ~A~%" (get-universal-time))' \
  --eval '(uiop:quit)'
