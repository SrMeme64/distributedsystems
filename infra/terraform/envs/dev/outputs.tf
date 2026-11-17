output "api_endpoint" {
  description = "Endpoint VIP del API una vez que Flux despliegue kube-vip."
  value       = module.k3s_nodes.api_endpoint
}

output "bootstrap_endpoint" {
  description = "Endpoint inicial del primer servidor K3s."
  value       = module.k3s_nodes.bootstrap_endpoint
}

output "bootstrap_node_ip" {
  description = "Dirección del primer servidor K3s."
  value       = module.k3s_nodes.bootstrap_node_ip
}

output "node_ips" {
  description = "Direcciones IPv4 reservadas de los tres servidores."
  value       = module.k3s_nodes.node_ips
}
