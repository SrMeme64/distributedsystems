terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
  }
}

resource "libvirt_pool" "cluster" {
  name = var.pool_name
  type = "dir"

  target {
    path = var.pool_path
  }
}

resource "libvirt_volume" "ubuntu_base" {
  name   = "${var.pool_name}-ubuntu-noble-base.qcow2"
  pool   = libvirt_pool.cluster.name
  source = var.image_url
  format = "qcow2"
}
