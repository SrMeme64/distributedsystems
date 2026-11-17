#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-store}"
backup_root="${1:-$HOME/.local/share/distributed-store/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$backup_root/$timestamp"
staging="$backup_root/.${timestamp}.partial.$$"
rabbitmq_file="/tmp/rabbitmq-definitions-$timestamp.json"

umask 077
mkdir -p "$backup_root"
if [[ -e "$destination" || -e "$staging" ]]; then
  echo "Backup destination already exists; choose another backup root or retry later." >&2
  exit 1
fi
mkdir "$staging"
chmod 700 "$staging"

cleanup() {
  kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
    rm -f "$rabbitmq_file" >/dev/null 2>&1 || true
  if [[ -d "$staging" ]]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT

kubectl -n "$namespace" wait \
  --for=condition=Ready \
  pod/mariadb-0 pod/mongodb-0 pod/rabbitmq-0 \
  --timeout=120s

kubectl -n "$namespace" exec mariadb-0 -- sh -ec '
  MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb-dump \
    --user="$MARIADB_USER" \
    --single-transaction \
    --routines \
    --triggers \
    "$MARIADB_DATABASE"
' > "$staging/catalog.sql"

kubectl -n "$namespace" exec mongodb-0 -- sh -ec '
  yaml_quote() {
    value=$(printf "%s" "$1" | sed "s/'\''/''/g")
    printf "'\''%s'\''" "$value"
  }
  config="$(mktemp /tmp/mongodump-config.XXXXXX)"
  trap '\''rm -f "$config"'\'' EXIT
  uri="mongodb://$MONGO_APP_USERNAME@127.0.0.1:27017/$MONGO_DB?authSource=$MONGO_DB"
  {
    printf "uri: %s\n" "$(yaml_quote "$uri")"
    printf "password: %s\n" "$(yaml_quote "$MONGO_APP_PASSWORD")"
  } > "$config"
  chmod 600 "$config"
  mongodump --config="$config" --archive --gzip
' > "$staging/reviews.archive.gz"

kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
  rabbitmqctl export_definitions "$rabbitmq_file" >/dev/null
kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
  cat "$rabbitmq_file" > "$staging/rabbitmq-definitions.json"

{
  printf 'created_utc=%s\n' "$timestamp"
  printf 'namespace=%s\n' "$namespace"
  printf 'cluster_context=%s\n' "$(kubectl config current-context)"
  printf '%s\n' 'RabbitMQ backup contains definitions, not queued messages.'
} > "$staging/README.txt"

(
  cd "$staging"
  sha256sum catalog.sql reviews.archive.gz rabbitmq-definitions.json > SHA256SUMS
)
chmod 600 "$staging"/*
mv "$staging" "$destination"

trap - EXIT
kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
  rm -f "$rabbitmq_file" >/dev/null
echo "Local backup created with private permissions: $destination"
