FROM eclipse-temurin:17-jre-alpine
ARG JMETER_VERSION=5.6.3
RUN apk add --no-cache bash curl \
 && curl -fsSL https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz | tar -xz -C /opt \
 && ln -s /opt/apache-jmeter-${JMETER_VERSION}/bin/jmeter /usr/local/bin/jmeter
ENV JVM_ARGS="-Xms256m -Xmx768m"
COPY run.sh /runbook/run.sh
RUN chmod 0755 /runbook/run.sh
