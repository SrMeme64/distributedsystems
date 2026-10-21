FROM python:3.13-alpine
RUN apk add --no-cache docker-cli
COPY run.sh chaosmonkey.py /runbook/
RUN chmod 0755 /runbook/run.sh
