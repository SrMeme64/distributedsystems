#!/bin/sh
# Runbook: Chaos Monkey. Usage: run.sh <outdir>   (parameters come from env)
OUT=$1; mkdir -p "$OUT"; echo $$ > "$OUT/pid"
exec python3 -u /runbook/chaosmonkey.py "$OUT"
