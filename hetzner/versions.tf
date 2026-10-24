terraform {
  required_version = ">= 1.8"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

# Reads the API token from HCLOUD_TOKEN, e.g.:
#   export HCLOUD_TOKEN=$(op read op://k3s/hetzner/token)
provider "hcloud" {}
