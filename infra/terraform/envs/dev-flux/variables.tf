variable "kubeconfig_path" {
  description = "Ruta del kubeconfig del clúster K3s ya creado."
  type        = string
  default     = "~/.kube/distributed-k3s.yaml"
}

variable "git_repository" {
  description = "URL HTTPS del repositorio Git que administrará Flux."
  type        = string
  default     = "https://github.com/SrMeme64/distributedsystems.git"
}

variable "github_token" {
  description = "Token GitHub privado con permiso de escritura al repositorio."
  type        = string
  sensitive   = true
}

variable "flux_path" {
  description = "Ruta relativa al repositorio que Flux reconciliará."
  type        = string
  default     = "clusters/dev"
}
