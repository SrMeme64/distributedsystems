#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
profile="${MINIKUBE_PROFILE:-distributed-local-one-node}"
secrets_file="$repository_root/deploy/overlays/local/secrets/lgtm.env"
compose_file="$repository_root/deploy/observability/compose.yaml"
image="grafana/otel-lgtm:0.41.0"

if [[ ! -f "$secrets_file" ]]; then
  mkdir -p "$(dirname "$secrets_file")"
  chmod 700 "$(dirname "$secrets_file")"
  python3 - "$secrets_file" <<'PY'
import os
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as file:
    file.write(f"GF_SECURITY_ADMIN_PASSWORD={secrets.token_urlsafe(32)}\n")
PY
fi

if ! grep -q '^GF_SECURITY_ADMIN_PASSWORD=.' "$secrets_file"; then
  echo "The local Grafana password is missing from the ignored secrets file." >&2
  exit 1
fi
chmod 600 "$secrets_file"

if ! DOCKER_HOST=unix:///var/run/docker.sock docker network inspect "$profile" >/dev/null 2>&1; then
  echo "Minikube network '$profile' was not found; start that profile first." >&2
  exit 1
fi

gateway="$(
  DOCKER_HOST=unix:///var/run/docker.sock docker network inspect "$profile" \
    --format '{{(index .IPAM.Config 0).Gateway}}'
)"
if [[ -z "$gateway" ]]; then
  echo "Could not determine the Minikube host-gateway address." >&2
  exit 1
fi

python3 - "$secrets_file" "$gateway" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
if not values.get("GF_SECURITY_ADMIN_PASSWORD"):
    print("The local Grafana password is missing from the ignored secrets file.", file=sys.stderr)
    raise SystemExit(1)
values["LGTM_OTLP_BIND_ADDRESS"] = sys.argv[2]
temporary = path.with_suffix(".tmp")
temporary.write_text(
    "".join(f"{key}={value}\n" for key, value in values.items()),
    encoding="utf-8",
)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

docker_config_directory="$(mktemp -d)"
cleanup() {
  rm -rf -- "$docker_config_directory"
}
trap cleanup EXIT

DOCKER_HOST=unix:///var/run/docker.sock docker --config "$docker_config_directory" pull "$image"
DOCKER_HOST=unix:///var/run/docker.sock \
  docker compose --env-file "$secrets_file" -f "$compose_file" up -d --pull never

for attempt in {1..120}; do
  if curl --silent --fail --max-time 2 http://127.0.0.1:3000/api/health >/dev/null; then
    echo "Local LGTM is ready at http://127.0.0.1:3000."
    echo "Grafana's generated admin password is in deploy/overlays/local/secrets/lgtm.env."
    exit 0
  fi
  sleep 2
done

echo "Grafana did not become ready; inspect the local LGTM container logs." >&2
exit 1
