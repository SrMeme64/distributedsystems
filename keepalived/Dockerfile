FROM alpine:3.21

RUN apk add --no-cache keepalived busybox-extras iproute2

COPY check-haproxy.sh /usr/local/bin/check-haproxy.sh
COPY keepalived-entrypoint.sh /usr/local/bin/keepalived-entrypoint.sh
RUN chmod 0755 /usr/local/bin/check-haproxy.sh /usr/local/bin/keepalived-entrypoint.sh

ARG KEEPALIVED_CONFIG
COPY ${KEEPALIVED_CONFIG} /etc/keepalived/keepalived.conf.template
RUN chmod 0644 /etc/keepalived/keepalived.conf.template

ENTRYPOINT ["/usr/local/bin/keepalived-entrypoint.sh"]
