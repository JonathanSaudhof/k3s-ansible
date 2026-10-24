terraform {
  required_version = ">= 1.8"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

# Reads the API token from HCLOUD_TOKEN, which the Makefile loads from ../.env.
provider "hcloud" {}
