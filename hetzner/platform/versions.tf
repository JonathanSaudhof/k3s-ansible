terraform {
  required_version = ">= 1.8"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# kubeconfig-hetzner is written by infra/ (terraform_data.bootstrap) and points at localhost:16443,
# so `make hetzner-tunnel` has to be up; `make hetzner-up` opens it for the run.
provider "kubernetes" {
  config_path = local.kubeconfig
}

locals {
  kubeconfig = abspath("${path.module}/../../kubeconfig-hetzner")
}

# Hostnames and zone come from stage 1, so they're configured in one place.
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../infra/terraform.tfstate"
  }
}
