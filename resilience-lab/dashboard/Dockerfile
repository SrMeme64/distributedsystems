FROM python:3.13-alpine
RUN apk add --no-cache docker-cli && pip install --no-cache-dir flask==3.1.*
WORKDIR /app
COPY app.py .
COPY static static
EXPOSE 8090
CMD ["python", "-u", "app.py"]
