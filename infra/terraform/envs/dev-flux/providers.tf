terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.10.0"
    }
  }
}

provider "flux" {
  kubernetes = {
    config_path = pathexpand(var.kubeconfig_path)
  }

  git = {
    url = var.git_repository
    http = {
      username = "git"
      password = var.github_token
    }
  }
}
