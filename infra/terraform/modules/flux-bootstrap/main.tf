terraform {
  required_providers {
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.10.0"
    }
  }
}

resource "flux_bootstrap_git" "cluster" {
  embedded_manifests     = true
  kustomization_override = file("${path.module}/kustomization_override.yaml")
  path                   = var.path
}
