#!/bin/sh
# Health check for the local HAProxy frontend.
#
# Returns 0 only when HAProxy answers with an HTTP status line. A bare TCP
# connect is not enough: when the container is paused/frozen the kernel still
# completes the handshake from the listen backlog, but no process replies.
# Any HTTP status (including 503) proves HAProxy itself is alive; backend
# health is handled by HAProxy's own checks.
set -u

port="${1:?usage: check-haproxy.sh <port>}"

response=$(
    printf 'GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' |
        nc -w 1 127.0.0.1 "$port" 2>/dev/null
) || exit 1

printf '%s\n' "$response" | grep -q '^HTTP/1\.[01] [1-5][0-9][0-9]'
