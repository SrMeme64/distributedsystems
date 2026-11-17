terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
  }
}

resource "libvirt_network" "cluster" {
  name      = var.name
  mode      = "nat"
  domain    = var.domain
  addresses = [var.ipv4_cidr]
  autostart = true

  dhcp {
    enabled = true
  }
}
