#!/bin/bash
set -euo pipefail

MONGO_HOST="${MONGO_BOOTSTRAP_HOST:-127.0.0.1:27017}"
MONGO_REPLICA_SET="${MONGO_REPLICA_SET:-rs0}"

echo "Waiting for ${MONGO_HOST} to accept connections..."
until mongosh --quiet --host "$MONGO_HOST" --eval 'db.adminCommand({ ping: 1 }).ok' | grep -q 1; do
  sleep 2
done

AUTH=(
  --username "${MONGO_ROOT_USERNAME:?MONGO_ROOT_USERNAME is required}"
  --password "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD is required}"
  --authenticationDatabase admin
)

AUTHENTICATED=false
if mongosh --quiet --host "$MONGO_HOST" "${AUTH[@]}" --eval 'db.adminCommand({ ping: 1 }).ok' | grep -q 1; then
  AUTHENTICATED=true
fi

mongo_shell() {
  if [ "$AUTHENTICATED" = true ]; then
    mongosh --quiet --host "$MONGO_HOST" "${AUTH[@]}" "$@"
  else
    mongosh --quiet --host "$MONGO_HOST" "$@"
  fi
}

echo "Initiating replica set ${MONGO_REPLICA_SET}..."
mongo_shell --eval "
  try {
    rs.initiate({
      _id: '${MONGO_REPLICA_SET}',
      members: [
        { _id: 0, host: 'mongo1:27017', priority: 2 },
        { _id: 1, host: 'mongo2:27017', priority: 1 },
        { _id: 2, host: 'mongo3:27017', priority: 1 },
      ],
    });
  } catch (error) {
    if (error.codeName !== 'AlreadyInitialized') {
      throw error;
    }
  }
"

echo "Waiting for a writable primary..."
for _ in $(seq 1 60); do
  if mongo_shell --eval 'db.hello().isWritablePrimary' | grep -q true; then
    break
  fi
  sleep 2
done

if ! mongo_shell --eval 'db.hello().isWritablePrimary' | grep -q true; then
  echo "Timed out waiting for the replica set primary." >&2
  exit 1
fi

if [ "$AUTHENTICATED" = false ]; then
  echo "Creating the initial administrator on the writable primary..."
  mongo_shell --eval "
    const admin = db.getSiblingDB('admin');
    admin.createUser({
      user: process.env.MONGO_ROOT_USERNAME,
      pwd: process.env.MONGO_ROOT_PASSWORD,
      roles: ['root'],
    });
  "
fi

if ! mongosh --quiet --host "$MONGO_HOST" "${AUTH[@]}" --eval 'db.adminCommand({ ping: 1 }).ok' | grep -q 1; then
  echo "MongoDB administrator authentication failed after initialization." >&2
  exit 1
fi

echo "Replica set ${MONGO_REPLICA_SET} has a writable primary."
