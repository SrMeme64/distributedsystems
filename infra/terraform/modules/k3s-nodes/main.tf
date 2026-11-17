terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
  }
}

locals {
  nodes = {
    server-1 = {
      ip        = var.node_ips[0]
      mac       = "52:54:00:fa:00:11"
      bootstrap = true
    }
    server-2 = {
      ip        = var.node_ips[1]
      mac       = "52:54:00:fa:00:12"
      bootstrap = false
    }
    server-3 = {
      ip        = var.node_ips[2]
      mac       = "52:54:00:fa:00:13"
      bootstrap = false
    }
  }

}

resource "libvirt_volume" "node" {
  for_each = local.nodes

  name           = "${var.cluster_name}-${each.key}.qcow2"
  pool           = var.pool_name
  base_volume_id = var.base_volume_id
  size           = 20 * 1024 * 1024 * 1024
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = local.nodes

  name = "${var.cluster_name}-${each.key}-cloudinit.iso"
  pool = var.pool_name
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname       = each.key
    api_vip        = var.api_vip
    k3s_token      = var.k3s_token
    k3s_version    = var.k3s_version
    server_url     = each.value.bootstrap ? "" : "https://${var.node_ips[0]}:6443"
    bootstrap      = each.value.bootstrap
    ssh_public_key = var.ssh_public_key
  })
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name       = "${var.cluster_name}-${each.key}"
  memory     = var.node_memory_mib
  vcpu       = var.node_vcpu
  autostart  = true
  qemu_agent = true
  cloudinit  = libvirt_cloudinit_disk.node[each.key].id

  disk {
    volume_id = libvirt_volume.node[each.key].id
  }

  network_interface {
    network_id     = var.network_id
    hostname       = each.key
    mac            = each.value.mac
    addresses      = [each.value.ip]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_port = "1"
    target_type = "virtio"
  }

  depends_on = [libvirt_volume.node]
}
