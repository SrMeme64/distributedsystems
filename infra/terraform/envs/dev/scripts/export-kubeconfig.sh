#!/usr/bin/env bash
set -Eeuo pipefail

terraform_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_ip="$(terraform -chdir="$terraform_root" output -raw bootstrap_node_ip)"
ssh_private_key="${K3S_SSH_PRIVATE_KEY:-$HOME/.ssh/distributed-k3s_ed25519}"
if [[ ! -r "$ssh_private_key" ]]; then
  printf 'No se puede leer la clave SSH privada: %s\n' "$ssh_private_key" >&2
  exit 1
fi

use_vip=false
if [[ "${1:-}" == "--vip" ]]; then
  use_vip=true
  shift
fi

if [[ "$#" -gt 1 ]]; then
  printf 'Uso: %s [--vip] [ruta-kubeconfig]\n' "$0" >&2
  exit 2
fi

if [[ "$use_vip" == true ]]; then
  api_endpoint="$(terraform -chdir="$terraform_root" output -raw api_endpoint)"
else
  api_endpoint="$(terraform -chdir="$terraform_root" output -raw bootstrap_endpoint)"
fi
kubeconfig_path="${1:-$HOME/.kube/distributed-k3s.yaml}"
kubeconfig_dir="$(dirname "$kubeconfig_path")"
mkdir -p "$kubeconfig_dir"
temporary_file="$(mktemp "${kubeconfig_path}.tmp.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

umask 077
ready=false
for ((attempt = 1; attempt <= 180; attempt++)); do
  if ssh \
    -q \
    -i "$ssh_private_key" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "ubuntu@${node_ip}" \
    'sudo test -s /etc/rancher/k3s/k3s.yaml && sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1'; then
    ready=true
    break
  fi
  sleep 5
done

if [[ "$ready" != true ]]; then
  printf 'El servidor K3s no quedó listo dentro de los 15 minutos esperados.\n' >&2
  exit 1
fi

ssh \
  -q \
  -i "$ssh_private_key" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  "ubuntu@${node_ip}" \
  'sudo cat /etc/rancher/k3s/k3s.yaml' |
  sed "s#https://127\\.0\\.0\\.1:6443#${api_endpoint}#" > "$temporary_file"

if ! grep -Fq "server: ${api_endpoint}" "$temporary_file"; then
  printf 'No se encontró el endpoint de API esperado en el kubeconfig recibido.\n' >&2
  exit 1
fi

chmod 0600 "$temporary_file"
mv -- "$temporary_file" "$kubeconfig_path"
printf 'Kubeconfig guardado en %s\n' "$kubeconfig_path"
