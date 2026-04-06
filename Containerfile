FROM fedora:43

RUN dnf install -y sbcl sqlite-libs git && dnf clean all

# Install ocicl
RUN OCICL_URL=$(curl -sL -o /dev/null -w '%{url_effective}' https://github.com/ocicl/ocicl/releases/latest) && \
    OCICL_VER=$(basename "$OCICL_URL") && \
    cd /tmp && \
    curl -sL "https://github.com/ocicl/ocicl/releases/download/${OCICL_VER}/ocicl-${OCICL_VER#v}-linux-amd64.tar.gz" \
    | tar xz && \
    cp ocicl /usr/local/bin/ && rm -rf ocicl README.md LICENSE THIRD-PARTY-LICENSES.txt && \
    ocicl setup > ~/.sbclrc

WORKDIR /app
COPY ocicl-bot.asd ocicl-bot.lisp ./

# Install CL dependencies
# Pin puri to the version with uri-is-ip6 (needed by drakma 2.0.10)
RUN ocicl install puri:20260406-4bbab89
RUN ocicl install cl-workflow completions legit cl-github-v3 cl-x509 jose \
    cl-base64 cl-ppcre cl-json drakma flexi-streams

# Pre-compile
RUN sbcl --noinform --non-interactive \
    --eval '(asdf:load-system :ocicl-bot)' \
    --eval '(format t "~&Build OK~%")'

COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
