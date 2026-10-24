FROM proxysql/proxysql:2.6.0

USER root

COPY proxysql.cnf.template /etc/proxysql.cnf.template
COPY render-and-run.sh /usr/local/bin/render-and-run.sh

RUN chmod 0755 /usr/local/bin/render-and-run.sh

ENTRYPOINT ["/usr/local/bin/render-and-run.sh"]
