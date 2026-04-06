FROM fedora:43

RUN dnf install -y sbcl sqlite-libs git npm && dnf clean all

# Install gemini CLI
RUN npm install -g @google/gemini-cli

# Install ocicl
RUN curl -sL https://github.com/ocicl/ocicl/releases/latest/download/ocicl-linux-x86_64 \
    -o /usr/local/bin/ocicl && chmod +x /usr/local/bin/ocicl && \
    ocicl setup > /tmp/ocicl-setup.lisp

WORKDIR /app
COPY ocicl-bot.asd ocicl-bot.lisp ./

# Install CL dependencies
RUN sbcl --noinform --non-interactive \
    --load /tmp/ocicl-setup.lisp \
    --eval '(ocicl:install "cl-workflow")' \
    --eval '(ocicl:install "legit")' \
    --eval '(ocicl:install "cl-github-v3")' \
    --eval '(ocicl:install "cl-x509")' \
    --eval '(ocicl:install "jose")' \
    --eval '(ocicl:install "cl-base64")' \
    --eval '(ocicl:install "cl-ppcre")' \
    --eval '(ocicl:install "cl-json")' \
    --eval '(ocicl:install "drakma")' \
    --eval '(ocicl:install "flexi-streams")'

# Pre-compile everything
RUN sbcl --noinform --non-interactive \
    --load /tmp/ocicl-setup.lisp \
    --eval '(asdf:load-system :ocicl-bot)' \
    --eval '(format t "~&Build OK~%")'

COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
