FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    nginx \
    fcgiwrap \
    gettext-base \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /repos /run/nginx /var/run

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD curl -sf http://localhost/health || exit 1

CMD ["/start.sh"]
