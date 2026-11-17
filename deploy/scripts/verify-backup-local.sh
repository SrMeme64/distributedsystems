#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 BACKUP_DIRECTORY" >&2
  exit 2
fi

namespace="${NAMESPACE:-store}"
backup_directory="$(cd "$1" && pwd)"
suffix="$(date -u +%Y%m%d%H%M%S)_$$"
mariadb_database="backup_verify_${suffix}"
mongodb_database="backup_verify_${suffix}"
rabbitmq_vhost="backup_verify_${suffix}"

for filename in catalog.sql reviews.archive.gz rabbitmq-definitions.json SHA256SUMS; do
  if [[ ! -s "$backup_directory/$filename" ]]; then
    echo "Missing or empty backup file: $backup_directory/$filename" >&2
    exit 1
  fi
done

(
  cd "$backup_directory"
  sha256sum --check SHA256SUMS
)

database_collision="$(
  kubectl -n "$namespace" exec mariadb-0 -- sh -ec \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --user=root --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '\''$1'\''"' \
    sh "$mariadb_database"
)"
if [[ "$database_collision" != 0 ]]; then
  echo "Temporary MariaDB database already exists; refusing to overwrite it." >&2
  exit 1
fi

mongodb_collision="$(
  kubectl -n "$namespace" exec mongodb-0 -- sh -ec \
    'mongosh --quiet --host 127.0.0.1 --username="$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase=admin --eval "db.adminCommand({listDatabases:1,nameOnly:true}).databases.some((item) => item.name === '\''$1'\'')"' \
    sh "$mongodb_database"
)"
if [[ "$mongodb_collision" == true ]]; then
  echo "Temporary MongoDB database already exists; refusing to overwrite it." >&2
  exit 1
fi

if kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
  rabbitmqctl list_vhosts name --silent | grep -Fxq "$rabbitmq_vhost"; then
  echo "Temporary RabbitMQ vhost already exists; refusing to overwrite it." >&2
  exit 1
fi

cleanup() {
  local failed=0
  kubectl -n "$namespace" exec mariadb-0 -- sh -ec \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --user=root --execute="DROP DATABASE IF EXISTS \`$1\`"' \
    sh "$mariadb_database" >/dev/null 2>&1 || failed=1
  kubectl -n "$namespace" exec mongodb-0 -- sh -ec \
    'mongosh --quiet --host 127.0.0.1 --username="$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase=admin --eval "db.getSiblingDB('\''$1'\'').dropDatabase()"' \
    sh "$mongodb_database" >/dev/null 2>&1 || failed=1
  kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
    rabbitmqctl delete_vhost "$rabbitmq_vhost" >/dev/null 2>&1 || failed=1
  if [[ $failed -ne 0 ]]; then
    echo "Warning: a temporary restore-test database or vhost may need manual cleanup." >&2
  fi
}
trap cleanup EXIT

kubectl -n "$namespace" wait \
  --for=condition=Ready \
  pod/mariadb-0 pod/mongodb-0 pod/rabbitmq-0 \
  --timeout=120s

kubectl -n "$namespace" exec mariadb-0 -- sh -ec \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --user=root --execute="CREATE DATABASE \`$1\`"' \
  sh "$mariadb_database"
kubectl -n "$namespace" exec -i mariadb-0 -- sh -ec \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --user=root "$1"' \
  sh "$mariadb_database" < "$backup_directory/catalog.sql"
mariadb_count="$(
  kubectl -n "$namespace" exec mariadb-0 -- sh -ec \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --user=root --batch --skip-column-names --execute="SELECT COUNT(*) FROM \`$1\`.products"' \
    sh "$mariadb_database"
)"
if [[ ! "$mariadb_count" =~ ^[0-9]+$ || "$mariadb_count" -lt 1 ]]; then
  echo "MariaDB restore verification found no products." >&2
  exit 1
fi
printf 'MariaDB restored in isolation: %s products\n' "$mariadb_count"

kubectl -n "$namespace" exec -i mongodb-0 -- sh -ec '
  target="$1"
  mongorestore \
    --host=127.0.0.1 \
    --username="$MONGO_INITDB_ROOT_USERNAME" \
    --password="$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase=admin \
    --nsFrom="$MONGO_DB.*" \
    --nsTo="$target.*" \
    --archive \
    --gzip
  count="$(mongosh --quiet --host 127.0.0.1 \
    --username="$MONGO_INITDB_ROOT_USERNAME" \
    --password="$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase=admin \
    --eval "db.getSiblingDB('\''$target'\'').product_reviews.countDocuments()")"
  if [ "$count" -lt 1 ]; then
    echo "MongoDB restore verification found no reviews." >&2
    exit 1
  fi
  printf "MongoDB restored in isolation: %s reviews\n" "$count"
' sh "$mongodb_database" < "$backup_directory/reviews.archive.gz"

python3 - "$backup_directory/rabbitmq-definitions.json" "$rabbitmq_vhost" <<'PY' |
import json
import sys
from pathlib import Path

definitions = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
vhost = sys.argv[2]
for section in ("users", "permissions", "topic_permissions", "global_parameters"):
    definitions[section] = []
definitions["vhosts"] = [{"name": vhost}]
for section in ("queues", "exchanges", "bindings", "policies", "parameters"):
    for item in definitions.get(section, []):
        if "vhost" in item:
            item["vhost"] = vhost
json.dump(definitions, sys.stdout)
PY
  kubectl -n "$namespace" exec -i rabbitmq-0 -c rabbitmq -- sh -ec '
    file="$(mktemp /tmp/restore-definitions.XXXXXX)"
    trap '\''rm -f "$file"'\'' EXIT
    cat > "$file"
    rabbitmqctl import_definitions "$file"
  '

rabbitmq_restored=false
for attempt in {1..30}; do
  queues="$(kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
    rabbitmqctl list_queues -p "$rabbitmq_vhost" name --silent 2>/dev/null || true)"
  exchanges="$(kubectl -n "$namespace" exec rabbitmq-0 -c rabbitmq -- \
    rabbitmqctl list_exchanges -p "$rabbitmq_vhost" name --silent 2>/dev/null || true)"
  if grep -Fxq 'reviews.created' <<<"$queues" &&
    grep -Fxq 'reviews.dlq' <<<"$queues" &&
    grep -Fxq 'reviews.events' <<<"$exchanges"; then
    rabbitmq_restored=true
    break
  fi
  sleep 1
done
if [[ "$rabbitmq_restored" != true ]]; then
  echo "RabbitMQ restore verification did not find the review queues and exchange." >&2
  exit 1
fi
echo "RabbitMQ definitions restored in an isolated vhost; review topology verified"
