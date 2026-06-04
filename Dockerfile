FROM alpine:3.20

RUN apk add --no-cache \
    git \
    nginx \
    fcgiwrap \
    gettext

RUN mkdir -p /repos /run/nginx /var/run

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD wget -q --spider http://localhost/health || exit 1

CMD ["/start.sh"]
