FROM fedora:43

RUN dnf install -y sbcl sqlite-libs git npm && dnf clean all

# Install gemini CLI
RUN npm install -g @google/gemini-cli

# Install ocicl
RUN curl -sL https://github.com/ocicl/ocicl/releases/latest/download/ocicl-linux-x86_64 \
    -o /usr/local/bin/ocicl && chmod +x /usr/local/bin/ocicl && \
    ocicl setup > ~/.sbclrc

WORKDIR /app
COPY ocicl-bot.asd ocicl-bot.lisp ./

# Install CL dependencies via ocicl CLI
RUN ocicl install cl-workflow legit cl-github-v3 cl-x509 jose \
    cl-base64 cl-ppcre cl-json drakma flexi-streams

# Pre-compile everything
RUN sbcl --noinform --non-interactive \
    --eval '(asdf:load-system :ocicl-bot)' \
    --eval '(format t "~&Build OK~%")'

COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
