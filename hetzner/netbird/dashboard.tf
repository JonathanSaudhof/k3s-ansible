# Objects first created in the dashboard, adopted by imports.tf.

data "netbird_group" "all" {
  name = "All" # built in, can't be managed
}

data "netbird_peer" "unraid" {
  name = "Unraid"
}

# Network resources need at least one group; no policy uses this one (they target the resource).
resource "netbird_group" "lan_hosts" {
  name = "lan-hosts"
}

resource "netbird_policy" "default" {
  name        = "Default"
  description = "This is a default rule that allows connections between all the resources"
  enabled     = true
  rule {
    name          = "Default"
    description   = "This is a default rule that allows connections between all the resources"
    action        = "accept"
    bidirectional = true
    enabled       = true
    protocol      = "all"
    sources       = [data.netbird_group.all.id]
    destinations  = [data.netbird_group.all.id]
  }
}

# --- home network: Home Assistant through the Unraid peer ----------------------------------------
resource "netbird_network" "home" {
  name = "home"
}

resource "netbird_network_router" "home" {
  network_id = netbird_network.home.id
  peer       = data.netbird_peer.unraid.id
  masquerade = true
  metric     = 9999
  enabled    = true
}

resource "netbird_network_resource" "homeassistant" {
  network_id = netbird_network.home.id
  name       = "homeassistant"
  address    = "192.168.178.50/32"
  groups     = [netbird_group.lan_hosts.id]
  enabled    = true
}

resource "netbird_policy" "homeassistant_access" {
  name    = "homeassistand Access"
  enabled = true
  rule {
    name          = "homeassistand Access"
    action        = "accept"
    bidirectional = false
    enabled       = true
    protocol      = "tcp"
    ports         = ["8123"]
    sources       = [data.netbird_group.all.id]
    destination_resource = {
      id   = netbird_network_resource.homeassistant.id
      type = "host"
    }
  }
}

# Public: not in apps.json because it sits behind the Unraid router (home), not netbird-router.
resource "netbird_reverse_proxy_service" "homeassistant" {
  name    = "homeassistant.${local.proxy_host}"
  domain  = "homeassistant.${local.proxy_host}"
  mode    = "http"
  enabled = true

  targets = [{
    target_id   = netbird_network_resource.homeassistant.id
    target_type = "host"
    host        = "192.168.178.50"
    port        = 8123
    protocol    = "http"
    enabled     = true
  }]

  # Home Assistant has its own login; the proxy adds none.
  auth = {
    bearer_auth   = { enabled = false }
    password_auth = { enabled = false, password = "" }
    pin_auth      = { enabled = false, pin = "" }
  }
}

# --- k3s API of the Proxmox cluster, through the homelab routers ---------------------------------
resource "netbird_network_resource" "k3s" {
  network_id = netbird_network.homelab.id
  name       = "k3s"
  address    = "192.168.178.150/32"
  groups     = [netbird_group.lan_hosts.id]
  enabled    = true
}

resource "netbird_policy" "k3s_access" {
  name        = "k3s Access"
  description = "homelab, Apps in the Proxmox k3s cluster, reached through apps/netbird-router"
  enabled     = true
  rule {
    name          = "k3s Access"
    description   = "homelab, Apps in the Proxmox k3s cluster, reached through apps/netbird-router"
    action        = "accept"
    bidirectional = false
    enabled       = true
    protocol      = "tcp"
    ports         = ["6443"]
    sources       = [netbird_group.homelab_apps.id]
    destination_resource = {
      id   = netbird_network_resource.k3s.id
      type = "host"
    }
  }
}
