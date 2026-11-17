variable "cluster_name" {
  description = "Prefijo de nombres para la red, el pool y los nodos."
  type        = string
  default     = "distributed-dev"
}

variable "libvirt_uri" {
  description = "URI del hipervisor libvirt local."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool_path" {
  description = "Ruta del pool de imágenes administrado por libvirt."
  type        = string
  default     = "/var/lib/libvirt/images/distributed-dev"
}

variable "network_cidr" {
  description = "Subred NAT privada para las máquinas K3s."
  type        = string
  default     = "192.168.250.0/24"
}

variable "node_ips" {
  description = "Direcciones DHCP reservadas para los tres servidores."
  type        = list(string)
  default     = ["192.168.250.11", "192.168.250.12", "192.168.250.13"]

  validation {
    condition     = length(var.node_ips) == 3
    error_message = "El clúster requiere exactamente tres direcciones de nodo."
  }
}

variable "api_vip" {
  description = "VIP anunciada por kube-vip para el API de Kubernetes."
  type        = string
  default     = "192.168.250.10"
}

variable "ubuntu_image_url" {
  description = "URL de la imagen cloud Ubuntu x86_64."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  description = "Clave SSH pública autorizada en los nodos; suministrarla por entorno."
  type        = string
}

variable "k3s_token" {
  description = "Token compartido por los servidores K3s; mantenerlo privado."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.k3s_token) >= 32
    error_message = "El token K3s debe tener al menos 32 caracteres."
  }
}

variable "k3s_version" {
  description = "Versión K3s fijada para los tres servidores."
  type        = string
  default     = "v1.37.2+k3s1"
}

variable "node_memory_mib" {
  description = "Memoria asignada a cada nodo en MiB."
  type        = number
  default     = 2048
}

variable "node_vcpu" {
  description = "CPU virtual asignada a cada nodo."
  type        = number
  default     = 2
}
