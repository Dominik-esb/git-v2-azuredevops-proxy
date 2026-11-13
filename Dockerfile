# Alpine: small and patched quickly. The Debian images carried ~500 CVEs that Debian marks as
# minor or won't fix; this base scans clean.
FROM alpine:3.24

# upgrade: pick up security fixes released since the base image was built.
# git-daemon provides git-http-backend; findutils provides `find -quit` for start.sh; jq parses
# the Azure DevOps API and builds the status page data.
RUN apk upgrade --no-cache \
 && apk add --no-cache \
    git \
    git-daemon \
    nginx \
    fcgiwrap \
    gettext-envsubst \
    ca-certificates \
    curl \
    openssl \
    findutils \
    jq

# Runs as an unprivileged user. Everything it writes is under /repos (the mirrors - mount a
# volume), /etc/git-proxy (generated config, TLS cert, Entra token) and /tmp (nginx pid, temp
# files and the fcgiwrap socket), so the root filesystem can be mounted read-only.
RUN addgroup -S -g 10001 git-proxy \
 && adduser -S -D -H -u 10001 -G git-proxy -h /nonexistent -s /sbin/nologin git-proxy \
 && mkdir -p /repos /etc/git-proxy \
 && chown 10001:10001 /repos /etc/git-proxy

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY ui/nginx-status.conf /etc/nginx/git-proxy-status.conf
COPY ui/nginx-status-headers.conf /etc/nginx/git-proxy-status-headers.conf
COPY ui/index.html ui/app.js ui/style.css /usr/share/git-proxy/ui/
COPY --chmod=755 ui/git-proxy-status ui/git-proxy-sync-one ui/git-proxy-sync-error ui/git-proxy-set-head /usr/local/bin/
COPY --chmod=755 ui/post-receive /usr/local/share/git-proxy/post-receive
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Shown on the status page; the release workflow passes the tag.
ARG VERSION=dev

# git's global config, in a writable place: there is no home directory.
ENV GIT_PROXY_VERSION=$VERSION \
    GIT_CONFIG_GLOBAL=/etc/git-proxy/gitconfig \
    HTTP_PORT=8080 \
    HTTPS_PORT=8443

USER 10001:10001

EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD curl -fsS -o /dev/null "http://localhost:${HTTP_PORT}/health" || exit 1

CMD ["/start.sh"]
