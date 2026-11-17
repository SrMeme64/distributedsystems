# Terraform para la plataforma

La ejecución elegida para este equipo es Terraform CLI local contra
KVM/libvirt. HCP Terraform también es una opción, pero para operar este
hipervisor local necesitaría un agente instalado en el mismo equipo; un
ejecutor alojado en la nube no tiene acceso directo a `/dev/kvm`.

## Alcance implementado

- `envs/dev`: red NAT aislada, volumen base Ubuntu y tres servidores K3s con
  etcd integrado. K3s firma el certificado para la VIP; Flux instala kube-vip
  como DaemonSet después del primer inicio.
- `envs/dev-flux`: inicio de Flux desde un kubeconfig existente. Se ejecuta
  después de crear el clúster.
- `envs/prod`: sin configuración aplicable hasta que se elijan un destino y
  almacenamiento productivos.

Las raíces `dev` y `dev-flux` usan estado local independiente, adecuado para
este equipo de desarrollo. Terraform guarda cada estado en su directorio raíz;
los archivos `*.tfstate` están excluidos de Git, pero contienen secretos como
el token K3s y deben permanecer protegidos. Usa `umask 077`, cifrado de disco y
copias de seguridad privadas. No compartas ni subas el estado.

MinIO Community no se pudo instalar desde sus fuentes públicas actuales; no se
usa MinIO AIStor sin aprobación de su licencia. Antes de compartir el estado o
definir producción, elige y configura un backend remoto S3 compatible con
cifrado, versionado y bloqueo.

## Requisitos del host

- CPU x86_64 con virtualización habilitada.
- Terraform `>= 1.11`, QEMU/KVM, libvirt y cloud-init.
- Servicio libvirt del sistema activo y acceso del usuario al socket de libvirt
  y a `/dev/kvm`.
- Una clave SSH pública local para acceder a las máquinas.

En Linux Mint/Ubuntu, el administrador del equipo debe instalar y activar
libvirt antes de aprovisionar:

```bash
sudo apt update
sudo apt install -y libvirt-daemon-system libvirt-clients qemu-system-x86 qemu-utils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
```

Después de agregar los grupos, cierra la sesión e inicia una nueva. Comprueba
el acceso con `virsh -c qemu:///system list --all` antes de usar Terraform.
Estas operaciones requieren autorización administrativa; no se ejecutan
automáticamente desde este repositorio.

Este entorno usa tres VM de 2 GiB cada una. Antes de aplicarlo, detén
temporalmente Minikube para liberar memoria; `minikube stop` conserva sus
volúmenes. No se ejecuta ese comando automáticamente.

## Preparación

Desde esta carpeta, prepara los archivos privados de configuración:

```bash
export PATH="$HOME/.local/bin:$PATH"
cd envs/dev
umask 077
cp terraform.tfvars.example terraform.tfvars
```

Revisa `terraform.tfvars`, especialmente la versión de K3s. Proporciona la
clave pública SSH y un token aleatorio de al menos 32 caracteres por entorno:

```bash
export TF_VAR_ssh_public_key="$(cat "$HOME/.ssh/distributed-k3s_ed25519.pub")"
export TF_VAR_k3s_token="$(cat "$HOME/.config/distributedsystems/terraform/dev-k3s-token")"
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
```

La clave SSH dedicada y el token aleatorio se guardan fuera del repositorio,
con permisos privados. Reutiliza el mismo token para planificar y aplicar; no
generes otro entre ambas operaciones.

Inspecciona el plan antes de ejecutar `terraform apply`. El estado incluye los
datos de cloud-init que permiten unir los nodos y, por tanto, el token K3s.
Protege `terraform.tfstate` y sus copias de seguridad con permisos mínimos y
cifrado de disco. No guardes planes, estados ni kubeconfig en Git.

Para crear el clúster:

```bash
terraform apply
```

El clúster usa la red privada `192.168.250.0/24`. Antes de desplegar Flux, el
API se alcanza por el primer nodo (`192.168.250.11:6443`). Después de que Flux
aplique el DaemonSet kube-vip, la VIP `192.168.250.10:6443` es el endpoint
estable. Verifica antes que la subred y la VIP no se superpongan con redes LAN,
VPN o Docker de este equipo.

## Flux

Una vez que los tres servidores estén listos, copia el kubeconfig del primer
nodo a una ruta local con permisos `0600`; el script usa el endpoint inicial del
primer nodo y espera hasta 15 minutos a que su API responda:

```bash
bash scripts/export-kubeconfig.sh
kubectl --kubeconfig "$HOME/.kube/distributed-k3s.yaml" wait \
  --for=condition=Ready nodes --all --timeout=20m
kubectl --kubeconfig "$HOME/.kube/distributed-k3s.yaml" get nodes
```

Luego configura `envs/dev-flux/terraform.tfvars`. El token de GitHub con permiso
de escritura se proporciona solo por entorno; conserva `umask 077`:

```bash
cd ../dev-flux
umask 077
cp terraform.tfvars.example terraform.tfvars
export TF_VAR_github_token='...'
terraform init
terraform plan
terraform apply
```

Flux escribe el bootstrap en `clusters/dev` del repositorio indicado y
reconcilia el DaemonSet kube-vip incluido en
`clusters/dev/flux-system/kube-vip`. La configuración de Flux añade ese
subdirectorio a su Kustomization sin reemplazar el manifiesto raíz que genera
el bootstrap. Revisa el commit que crea en Git y espera a que kube-vip esté
disponible antes de cambiar el kubeconfig al endpoint estable:

```bash
kubectl --kubeconfig "$HOME/.kube/distributed-k3s.yaml" \
  -n kube-system rollout status daemonset/kube-vip --timeout=10m
cd ../dev
bash scripts/export-kubeconfig.sh --vip
kubectl --kubeconfig "$HOME/.kube/distributed-k3s.yaml" get nodes
```

La opción predeterminada del script usa el endpoint inicial del primer nodo;
`--vip` lo cambia a la VIP después de instalar kube-vip.
El script usa `~/.ssh/distributed-k3s_ed25519` para SSH por defecto; si la clave
está en otra ruta, configura `K3S_SSH_PRIVATE_KEY` en el entorno.

## Validación sin infraestructura

La CI comprueba formato, validación sin backend remoto, TFLint, Checkov y el
renderizado de los manifiestos Kustomize. Esas comprobaciones no crean máquinas
ni necesitan credenciales de almacenamiento. No prueban el acceso al daemon
libvirt ni sustituyen la revisión de un `terraform plan` real.
