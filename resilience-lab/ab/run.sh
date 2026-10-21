#!/bin/sh
# Runbook: Apache Bench. Usage: run.sh <outdir>   (parameters come from env)
set -u
OUT=$1; mkdir -p "$OUT"; echo $$ > "$OUT/pid"
: "${TARGET_URL:=http://presentation-entry/}" "${REQUESTS:=1000}" "${CONCURRENCY:=20}" "${TIMEOUT:=30}" "${KEEPALIVE:=false}"

FLAGS="-r -l"   # -r keep going on socket errors, -l tolerate variable length bodies
[ "$KEEPALIVE" = "true" ] && FLAGS="$FLAGS -k"
echo "+ ab -n $REQUESTS -c $CONCURRENCY -s $TIMEOUT $FLAGS $TARGET_URL"
# shellcheck disable=SC2086
ab -n "$REQUESTS" -c "$CONCURRENCY" -s "$TIMEOUT" $FLAGS -e "$OUT/percentiles.csv" "$TARGET_URL"
