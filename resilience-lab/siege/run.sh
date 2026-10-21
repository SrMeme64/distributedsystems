#!/bin/sh
# Runbook: Siege. Usage: run.sh <outdir>   (parameters come from env)
set -u
OUT=$1; mkdir -p "$OUT"; echo $$ > "$OUT/pid"
: "${URLS:=http://presentation-entry/}" "${CONCURRENCY:=20}" "${DURATION:=30}" "${DELAY:=1}" "${BENCHMARK:=true}"

printf '%s\n' "$URLS" | sed '/^[[:space:]]*$/d' > "$OUT/urls.txt"
MODE="-d $DELAY"
[ "$BENCHMARK" = "true" ] && MODE="-b"
echo "+ siege -c $CONCURRENCY -t ${DURATION}S $MODE -f urls.txt"
cat "$OUT/urls.txt"
# siege prints its report on stderr and exits non-zero when availability is low
siege -c "$CONCURRENCY" -t "${DURATION}S" $MODE -f "$OUT/urls.txt" 2>&1
