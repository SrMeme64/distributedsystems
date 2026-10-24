#!/bin/bash
# Chooses the Galera bootstrap mode for the first node.
#
# The Bitnami image bootstraps whenever MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes.
# When galera1 is stopped on its own, Galera writes safe_to_bootstrap=0 because
# the rest of the cluster stays up. A later `docker compose start galera1`
# would then refuse to start. This wrapper bootstraps only when there is no
# data or when this node was the last one to leave the primary component;
# otherwise it joins the cluster that is already running.
#
# If every node is down and none has safe_to_bootstrap=1, mysqld still refuses
# to bootstrap from stale data. Recover the node with the most advanced
# position manually, as described in the README.
set -euo pipefail

data_dir="${MARIADB_DATA_DIR:-/bitnami/mariadb/data}"
grastate="${data_dir}/grastate.dat"

if [ ! -d "${data_dir}/mysql" ]; then
  echo "galera-entrypoint: no data in ${data_dir}; bootstrapping a new cluster"
  export MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
elif grep -Eq '^safe_to_bootstrap:[[:space:]]*1' "${grastate}" 2>/dev/null; then
  echo "galera-entrypoint: safe_to_bootstrap=1; bootstrapping the cluster"
  export MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
else
  echo "galera-entrypoint: data found and safe_to_bootstrap!=1; joining the running cluster"
  export MARIADB_GALERA_CLUSTER_BOOTSTRAP=no
fi

exec /opt/bitnami/scripts/mariadb-galera/entrypoint.sh \
  /opt/bitnami/scripts/mariadb-galera/run.sh
