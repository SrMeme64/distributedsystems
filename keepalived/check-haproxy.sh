#!/bin/sh

response=$(
    printf 'GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' |
        nc -w 2 127.0.0.1 "$1" 2>/dev/null
) || exit 1

printf '%s\n' "$response" | grep -q '^HTTP/1\.[01] 200'