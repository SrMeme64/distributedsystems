variable "cluster_name" {
  description = "Prefijo de nombres para los nodos."
  type        = string
}

variable "network_id" {
  description = "Identificador de la red libvirt."
  type        = string
}

variable "pool_name" {
  description = "Pool libvirt para discos de nodos y cloud-init."
  type        = string
}

variable "base_volume_id" {
  description = "Imagen Ubuntu cloud usada como backing volume."
  type        = string
}

variable "api_vip" {
  description = "VIP de kube-vip para la API de Kubernetes."
  type        = string
}

variable "node_ips" {
  description = "Direcciones reservadas para los tres servidores."
  type        = list(string)

  validation {
    condition     = length(var.node_ips) == 3
    error_message = "Se requieren tres direcciones IPv4."
  }
}

variable "ssh_public_key" {
  description = "Clave SSH pública que se autoriza en cada nodo."
  type        = string
}

variable "k3s_token" {
  description = "Token privado para unir los servidores K3s."
  type        = string
  sensitive   = true
}

variable "k3s_version" {
  description = "Versión fijada de K3s."
  type        = string
}

variable "node_memory_mib" {
  description = "Memoria por nodo en MiB."
  type        = number
}

variable "node_vcpu" {
  description = "CPU virtual por nodo."
  type        = number
}
