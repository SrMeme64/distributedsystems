variable "name" {
  description = "Nombre de la red libvirt."
  type        = string
}

variable "domain" {
  description = "Dominio DNS interno de la red."
  type        = string
}

variable "ipv4_cidr" {
  description = "Subred IPv4 privada de la red NAT."
  type        = string
}
