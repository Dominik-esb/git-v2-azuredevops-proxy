FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    nginx \
    fcgiwrap \
    gettext-base \
    ca-certificates \
    curl \
    wget \
    openssl \
 && rm -rf /var/lib/apt/lists/*

# Runs as an unprivileged user. Everything it writes is under /repos (the mirrors - mount a
# volume), /etc/git-proxy (generated config, TLS cert, Entra token) and /tmp (nginx pid, temp
# files and the fcgiwrap socket), so the root filesystem can be mounted read-only.
RUN groupadd --system --gid 10001 git-proxy \
 && useradd --system --uid 10001 --gid 10001 --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin git-proxy \
 && mkdir -p /repos /etc/git-proxy \
 && chown 10001:10001 /repos /etc/git-proxy

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

# git's global config, in a writable place: there is no home directory.
ENV GIT_CONFIG_GLOBAL=/etc/git-proxy/gitconfig \
    HTTP_PORT=8080 \
    HTTPS_PORT=8443

USER 10001:10001

EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD wget -q --spider "http://localhost:${HTTP_PORT}/health" || exit 1

CMD ["/start.sh"]
