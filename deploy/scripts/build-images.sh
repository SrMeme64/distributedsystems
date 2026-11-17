#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
profile="${MINIKUBE_PROFILE:-distributed-local-one-node}"
collector_image="otel/opentelemetry-collector-contrib:0.140.0"
rabbitmq_image="rabbitmq:4.2-management-alpine"
if [[ -n "${MINIKUBE_BIN:-}" ]]; then
  minikube="$MINIKUBE_BIN"
elif command -v minikube >/dev/null 2>&1; then
  minikube="$(command -v minikube)"
else
  minikube="$HOME/.local/bin/minikube"
fi
docker_config_directory="$(mktemp -d)"

cleanup() {
  rm -rf -- "$docker_config_directory"
}
trap cleanup EXIT

if [[ ! -x "$minikube" ]]; then
  echo "Minikube not found at $minikube; set MINIKUBE_BIN or install it in ~/.local/bin." >&2
  exit 1
fi

docker --config "$docker_config_directory" build \
  --tag store-catalog-api:dev \
  --file "$repository_root/application/Dockerfile" \
  "$repository_root/application"
docker --config "$docker_config_directory" build \
  --tag store-web:dev \
  --file "$repository_root/web/Dockerfile" \
  "$repository_root/web"
docker --config "$docker_config_directory" pull "$collector_image"
docker --config "$docker_config_directory" pull "$rabbitmq_image"

DOCKER_HOST=unix:///var/run/docker.sock "$minikube" image load \
  --profile="$profile" --daemon --overwrite store-catalog-api:dev
DOCKER_HOST=unix:///var/run/docker.sock "$minikube" image load \
  --profile="$profile" --daemon --overwrite store-web:dev
DOCKER_HOST=unix:///var/run/docker.sock "$minikube" image load \
  --profile="$profile" --daemon --overwrite "$collector_image"
DOCKER_HOST=unix:///var/run/docker.sock "$minikube" image load \
  --profile="$profile" --daemon --overwrite "$rabbitmq_image"
