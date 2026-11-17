output "pool_name" {
  description = "Nombre del pool del clúster."
  value       = libvirt_pool.cluster.name
}

output "base_volume_id" {
  description = "Identificador de la imagen Ubuntu base."
  value       = libvirt_volume.ubuntu_base.id
}
