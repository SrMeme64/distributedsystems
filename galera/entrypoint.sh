#!/bin/bash
# Chooses the Galera bootstrap mode for the first node.
#
# The Bitnami image bootstraps whenever MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes.
# This wrapper decides between bootstrapping and joining:
#   - no data: bootstrap a new cluster.
#   - safe_to_bootstrap=1: this node was the last to leave the primary
#     component, so it can bootstrap safely.
#   - a peer is reachable: join the running cluster.
#   - no peer reachable: if this node is the fallback bootstrap node, force
#     bootstrap so an abrupt shutdown does not require manual repair.
#
# The fallback is intended for a single Docker host. If the data on this node
# could be behind another node, recover manually with wsrep-recover instead of
# relying on the fallback.
set -euo pipefail

data_dir="${MARIADB_DATA_DIR:-/bitnami/mariadb/data}"
grastate="${data_dir}/grastate.dat"
peers="${GALERA_PEERS:-}"
wait_seconds="${GALERA_PEER_WAIT_SECONDS:-20}"

log() {
  echo "galera-entrypoint: $*"
}

peer_is_primary() {
  local peer
  local status
  for peer in $peers; do
    status="$(timeout 6 mariadb --protocol=tcp --connect-timeout=3 \
      -h "${peer}" -P 3306 -u root -p"${MARIADB_ROOT_PASSWORD}" \
      -N -s -e "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null |
      awk '$1 == "wsrep_cluster_status" { print $2; exit }')"
    if [ "${status}" = "Primary" ]; then
      return 0
    fi
  done
  return 1
}

safe_to_bootstrap() {
  grep -Eq '^safe_to_bootstrap:[[:space:]]*1' "${grastate}" 2>/dev/null
}

mode=""

if [ ! -d "${data_dir}/mysql" ]; then
  log "no data in ${data_dir}; bootstrapping a new cluster"
  mode="bootstrap"
elif safe_to_bootstrap; then
  log "safe_to_bootstrap=1; bootstrapping the cluster"
  mode="bootstrap"
else
  log "data found and safe_to_bootstrap!=1; waiting up to ${wait_seconds}s for a primary peer"
  deadline=$((SECONDS + wait_seconds))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if peer_is_primary; then
      log "a peer is Primary; joining the running cluster"
      mode="join"
      break
    fi
    sleep 2
  done

  if [ -z "${mode}" ]; then
    if [ "${GALERA_BOOTSTRAP_FALLBACK:-no}" = "yes" ]; then
      log "no peer is Primary after ${wait_seconds}s; forcing bootstrap on this node"
      mode="bootstrap-force"
    else
      log "no peer is Primary; joining (this node is not the fallback bootstrap node)"
      mode="join"
    fi
  fi
fi

case "${mode}" in
  bootstrap)
    export MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
    ;;
  bootstrap-force)
    export MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
    export MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes
    ;;
  join)
    export MARIADB_GALERA_CLUSTER_BOOTSTRAP=no
    ;;
esac

exec /opt/bitnami/scripts/mariadb-galera/entrypoint.sh \
  /opt/bitnami/scripts/mariadb-galera/run.sh
