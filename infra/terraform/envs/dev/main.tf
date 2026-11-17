module "network" {
  source = "../../modules/network"

  name      = "${var.cluster_name}-network"
  domain    = "${var.cluster_name}.local"
  ipv4_cidr = var.network_cidr
}

module "storage" {
  source = "../../modules/storage"

  pool_name = "${var.cluster_name}-pool"
  pool_path = var.libvirt_pool_path
  image_url = var.ubuntu_image_url
}

module "k3s_nodes" {
  source = "../../modules/k3s-nodes"

  cluster_name    = var.cluster_name
  network_id      = module.network.id
  pool_name       = module.storage.pool_name
  base_volume_id  = module.storage.base_volume_id
  api_vip         = var.api_vip
  node_ips        = var.node_ips
  ssh_public_key  = trimspace(var.ssh_public_key)
  k3s_token       = var.k3s_token
  k3s_version     = var.k3s_version
  node_memory_mib = var.node_memory_mib
  node_vcpu       = var.node_vcpu
}
