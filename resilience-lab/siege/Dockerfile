FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends siege procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /root/.siege && siege.config >/dev/null 2>&1 || true
COPY run.sh /runbook/run.sh
RUN chmod 0755 /runbook/run.sh
