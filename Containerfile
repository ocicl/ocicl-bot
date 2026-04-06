FROM fedora:43

RUN dnf install -y sbcl sqlite-libs git && dnf clean all

# Install ocicl
RUN OCICL_URL=$(curl -sL -o /dev/null -w '%{url_effective}' https://github.com/ocicl/ocicl/releases/latest) && \
    OCICL_VER=$(basename "$OCICL_URL") && \
    curl -sL "https://github.com/ocicl/ocicl/releases/download/${OCICL_VER}/ocicl-${OCICL_VER#v}-linux-amd64.tar.gz" \
    | tar xz --strip-components=0 -C /usr/local/bin ocicl && \
    ocicl setup > ~/.sbclrc

WORKDIR /app
COPY ocicl-bot.asd ocicl-bot.lisp ./

# Install CL dependencies
RUN ocicl install cl-workflow completions legit cl-github-v3 cl-x509 jose \
    cl-base64 cl-ppcre cl-json drakma flexi-streams

# Pre-compile
RUN sbcl --noinform --non-interactive \
    --eval '(asdf:load-system :ocicl-bot)' \
    --eval '(format t "~&Build OK~%")'

COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
