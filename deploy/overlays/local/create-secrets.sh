#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
environment_file="$repository_root/.env.exam"
secrets_directory="$repository_root/deploy/overlays/local/secrets"

if [[ ! -f "$environment_file" ]]; then
  echo "Missing $environment_file; create it from the documented local environment template." >&2
  exit 1
fi

python3 - "$environment_file" "$secrets_directory" <<'PY'
import os
import secrets
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
values = {}

for raw_line in source.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    values[key.strip()] = value

files = {
    "api.secret": {
        "DB_NAME": "CATALOG_DB_NAME",
        "DB_USER": "CATALOG_DB_USER",
        "DB_PASSWORD": "CATALOG_DB_PASSWORD",
        "MONGO_DB": "MONGO_DB_NAME",
        "MONGO_USER": "MONGO_APP_USERNAME",
        "MONGO_PASSWORD": "MONGO_APP_PASSWORD",
    },
    "mariadb.secret": {
        "MARIADB_ROOT_PASSWORD": "MARIADB_ROOT_PASSWORD",
        "MARIADB_DATABASE": "CATALOG_DB_NAME",
        "MARIADB_USER": "CATALOG_DB_USER",
        "MARIADB_PASSWORD": "CATALOG_DB_PASSWORD",
    },
    "mongodb.secret": {
        "MONGO_INITDB_DATABASE": "MONGO_DB_NAME",
        "MONGO_INITDB_ROOT_USERNAME": "MONGO_ROOT_USERNAME",
        "MONGO_INITDB_ROOT_PASSWORD": "MONGO_ROOT_PASSWORD",
        "MONGO_APP_USERNAME": "MONGO_APP_USERNAME",
        "MONGO_APP_PASSWORD": "MONGO_APP_PASSWORD",
        "MONGO_DB": "MONGO_DB_NAME",
    },
}

missing = sorted({key for mapping in files.values() for key in mapping.values() if key not in values or not values[key]})
if missing:
    print("Missing required settings in .env.exam: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)

destination.mkdir(parents=True, exist_ok=True)
os.chmod(destination, 0o700)
for filename, mapping in files.items():
    content = "".join(f"{key}={values[source_key]}\n" for key, source_key in mapping.items())
    target = destination / filename
    target.write_text(content, encoding="utf-8")
    os.chmod(target, 0o600)

rabbitmq_secret = destination / "rabbitmq.secret"
if not rabbitmq_secret.exists():
    password = secrets.token_urlsafe(32)
    rabbitmq_secret.write_text(
        "\n".join(
            (
                "RABBITMQ_DEFAULT_USER=store",
                f"RABBITMQ_DEFAULT_PASS={password}",
                "RABBITMQ_DEFAULT_VHOST=store",
                f"RABBITMQ_URL=amqp://store:{password}@rabbitmq:5672/store",
                "",
            )
        ),
        encoding="utf-8",
    )
required_rabbitmq_keys = {
    line.split("=", 1)[0]
    for line in rabbitmq_secret.read_text(encoding="utf-8").splitlines()
    if "=" in line and line.split("=", 1)[1]
}
if not {
    "RABBITMQ_DEFAULT_USER",
    "RABBITMQ_DEFAULT_PASS",
    "RABBITMQ_DEFAULT_VHOST",
    "RABBITMQ_URL",
}.issubset(required_rabbitmq_keys):
    print("Local RabbitMQ credentials are incomplete.", file=sys.stderr)
    raise SystemExit(1)
os.chmod(rabbitmq_secret, 0o600)

lgtm_secret = destination / "lgtm.env"
if not lgtm_secret.exists():
    lgtm_secret.write_text(
        f"GF_SECURITY_ADMIN_PASSWORD={secrets.token_urlsafe(32)}\n",
        encoding="utf-8",
    )
if not any(
    line.startswith("GF_SECURITY_ADMIN_PASSWORD=") and line.split("=", 1)[1]
    for line in lgtm_secret.read_text(encoding="utf-8").splitlines()
):
    print("Local Grafana password is missing from deploy/overlays/local/secrets/lgtm.env.", file=sys.stderr)
    raise SystemExit(1)
os.chmod(lgtm_secret, 0o600)
PY

echo "Local Kubernetes Secrets generated from .env.exam (values were not printed)."
