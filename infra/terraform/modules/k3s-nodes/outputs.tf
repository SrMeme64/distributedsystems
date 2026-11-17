output "api_endpoint" {
  description = "Endpoint VIP del API una vez que Flux despliegue kube-vip."
  value       = "https://${var.api_vip}:6443"
}

output "bootstrap_endpoint" {
  description = "Endpoint inicial del servidor K3s antes de desplegar kube-vip."
  value       = "https://${var.node_ips[0]}:6443"
}

output "bootstrap_node_ip" {
  description = "Dirección del primer servidor para acceso SSH."
  value       = var.node_ips[0]
}

output "node_ips" {
  description = "Direcciones IPv4 reservadas de los servidores K3s."
  value       = var.node_ips
}
