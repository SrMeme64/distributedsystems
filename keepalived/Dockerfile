FROM alpine:3.21

RUN apk add --no-cache keepalived busybox-extras

COPY check-haproxy.sh /usr/local/bin/check-haproxy.sh
RUN chmod 0755 /usr/local/bin/check-haproxy.sh

ARG KEEPALIVED_CONFIG
COPY ${KEEPALIVED_CONFIG} /etc/keepalived/keepalived.conf
RUN chmod 0644 /etc/keepalived/keepalived.conf

ENTRYPOINT ["sh", "-c", "rm -f /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid /run/keepalived/checkers.pid; exec keepalived --dont-fork --log-console --use-file=/etc/keepalived/keepalived.conf"]
