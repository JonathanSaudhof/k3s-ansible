# Publishes homelab apps through the NetBird reverse proxy on Hetzner:
#   internet -> <app>.<zone> (`*` record, infra/) -> netbird-proxy -> WireGuard -> homelab routing peer
#   (apps/netbird-router in k3s-configuration) -> the app's MetalLB IP in the LAN.
locals {
  apps = jsondecode(file("${path.module}/../apps.json")).apps
  # The proxy's own domain (NB_PROXY_DOMAIN), so <app>.<proxy_host> needs no custom domain.
  proxy_host = data.terraform_remote_state.infra.outputs.proxy_host
  # One network resource per LAN host, even if several apps share it (affine + affine-mcp).
  app_hosts = toset([for a in local.apps : a.host])
}

# --- routing peer in the homelab ------------------------------------------------------------------
resource "netbird_group" "homelab_routers" {
  name = "homelab-routers"
}

resource "netbird_group" "homelab_apps" {
  name = "homelab-apps"
}

resource "netbird_setup_key" "homelab_router" {
  name        = "homelab-router"
  type        = "reusable" # every router replica and pod restart registers with it
  auto_groups = [netbird_group.homelab_routers.id]
  ephemeral   = true # pods come and go; stale peers are removed after 10 min offline
  usage_limit = 0
}

resource "netbird_network" "homelab" {
  name        = "homelab"
  description = "Apps in the Proxmox k3s cluster, reached through apps/netbird-router"
}

resource "netbird_network_router" "homelab" {
  network_id  = netbird_network.homelab.id
  peer_groups = [netbird_group.homelab_routers.id]
  masquerade  = true # the apps answer the router's LAN IP, so no routes back are needed
  metric      = 9999
  enabled     = true
}

resource "netbird_network_resource" "app_host" {
  for_each   = local.app_hosts
  network_id = netbird_network.homelab.id
  name       = "homelab-${replace(each.key, ".", "-")}"
  address    = "${each.key}/32"
  groups     = [netbird_group.homelab_apps.id]
  enabled    = true
}

# --- public services ------------------------------------------------------------------------------
resource "netbird_reverse_proxy_service" "app" {
  for_each = local.apps
  name     = each.key
  domain   = "${each.key}.${local.proxy_host}"
  mode     = "http"
  enabled  = true

  targets = [{
    target_id   = netbird_network_resource.app_host[each.value.host].id
    target_type = "host"
    host        = each.value.host
    port        = each.value.port
    protocol    = "http"
  }]

  # The apps keep their own login (Logto OIDC); the proxy doesn't add one.
  auth             = {}
  pass_host_header = true
}

# --- setup key for the homelab router (k3s-configuration: make install-netbird-router) ------------
resource "kubernetes_namespace_v1" "netbird" {
  metadata {
    name = "netbird"
  }
}

resource "kubernetes_secret_v1" "setup_key" {
  metadata {
    name      = "netbird-setup-key"
    namespace = kubernetes_namespace_v1.netbird.metadata[0].name
  }
  data = {
    NB_SETUP_KEY = netbird_setup_key.homelab_router.key
  }
}
