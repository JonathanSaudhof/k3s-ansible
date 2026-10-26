terraform {
  required_version = ">= 1.8"

  required_providers {
    netbird = {
      source  = "netbirdio/netbird"
      version = "~> 0.0.10"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }
}

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../infra/terraform.tfstate"
  }
}

# Token: NB_PAT from ../../.env, a PAT of a NetBird service user with admin role. It can only be made
# in the dashboard once the server runs, which is why this stage is separate from platform/.
provider "netbird" {
  management_url = "https://${data.terraform_remote_state.infra.outputs.netbird_host}"
}

# The homelab (Proxmox) cluster, for the routing peer's setup key. Same kubeconfig as
# ../k3s-configuration, which uses the default one.
provider "kubernetes" {
  config_path = pathexpand(var.homelab_kubeconfig)
}

variable "homelab_kubeconfig" {
  description = "kubeconfig of the Proxmox k3s cluster that runs apps/netbird-router"
  type        = string
  default     = "~/.kube/config"
}
