variable "pool_name" {
  description = "Nombre del pool de almacenamiento libvirt."
  type        = string
}

variable "pool_path" {
  description = "Ruta del pool en el host."
  type        = string
}

variable "image_url" {
  description = "URL de la imagen cloud base."
  type        = string
}
