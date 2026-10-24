#!/bin/sh
set -eu

: "${PROXYSQL_ADMIN_PASSWORD:?PROXYSQL_ADMIN_PASSWORD is required}"
: "${PROXYSQL_MONITOR_USER:?PROXYSQL_MONITOR_USER is required}"
: "${PROXYSQL_MONITOR_PASSWORD:?PROXYSQL_MONITOR_PASSWORD is required}"
: "${CATALOG_DB_USER:?CATALOG_DB_USER is required}"
: "${CATALOG_DB_PASSWORD:?CATALOG_DB_PASSWORD is required}"
: "${CATALOG_DB_NAME:?CATALOG_DB_NAME is required}"

# Escape the characters that are special to sed's replacement string.
escape() {
  printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

sed \
  -e "s|__ADMIN_PASSWORD__|$(escape "$PROXYSQL_ADMIN_PASSWORD")|g" \
  -e "s|__MONITOR_USER__|$(escape "$PROXYSQL_MONITOR_USER")|g" \
  -e "s|__MONITOR_PASSWORD__|$(escape "$PROXYSQL_MONITOR_PASSWORD")|g" \
  -e "s|__APP_USER__|$(escape "$CATALOG_DB_USER")|g" \
  -e "s|__APP_PASSWORD__|$(escape "$CATALOG_DB_PASSWORD")|g" \
  -e "s|__APP_DB__|$(escape "$CATALOG_DB_NAME")|g" \
  /etc/proxysql.cnf.template > /etc/proxysql.cnf

# The container does not mount a data directory, so every start rebuilds the
# runtime configuration from this file. That keeps the Compose file as the
# single source of truth for the proxy rules.
exec proxysql --initial -f -c /etc/proxysql.cnf
