# Traefik routing on websecure, as in NetBird's getting-started.sh:
# - netbird host: gRPC (h2c) and HTTP paths to the server, everything else to the dashboard; Traefik
#   gets the certificate from the "letsencrypt" resolver bootstrap.sh configures.
# - any other SNI: TLS passthrough to the reverse proxy, which terminates TLS itself.
locals {
  host = "Host(`${local.netbird}`)"
  tls  = { certResolver = "letsencrypt" }
}

resource "kubernetes_manifest" "netbird_routes" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "netbird"
      namespace = local.ns
    }
    spec = {
      entryPoints = ["websecure"]
      tls         = local.tls
      routes = [
        {
          kind     = "Rule"
          match    = "${local.host} && (PathPrefix(`/signalexchange.SignalExchange/`) || PathPrefix(`/management.ManagementService/`) || PathPrefix(`/management.ProxyService/`))"
          priority = 100
          services = [{ name = kubernetes_service_v1.server.metadata[0].name, port = 80, scheme = "h2c" }]
        },
        {
          kind     = "Rule"
          match    = "${local.host} && (PathPrefix(`/relay`) || PathPrefix(`/ws-proxy/`) || PathPrefix(`/api`) || PathPrefix(`/oauth2`))"
          priority = 100
          services = [{ name = kubernetes_service_v1.server.metadata[0].name, port = 80 }]
        },
        {
          kind     = "Rule"
          match    = local.host
          priority = 1
          services = [{ name = kubernetes_service_v1.dashboard.metadata[0].name, port = 80 }]
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "redirect_https" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "redirect-https"
      namespace = local.ns
    }
    spec = {
      redirectScheme = { scheme = "https", permanent = true }
    }
  }
}

# ACME http-01 challenges on web are answered by Traefik before any router.
resource "kubernetes_manifest" "netbird_http" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "netbird-http"
      namespace = local.ns
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        kind        = "Rule"
        match       = local.host
        middlewares = [{ name = kubernetes_manifest.redirect_https.manifest.metadata.name }]
        services    = [{ name = kubernetes_service_v1.dashboard.metadata[0].name, port = 80 }]
      }]
    }
  }
}

resource "kubernetes_manifest" "proxy_protocol" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransportTCP"
    metadata = {
      name      = "pp-v2"
      namespace = local.ns
    }
    spec = {
      proxyProtocol = { version = 2 }
    }
  }
}

# HostSNI(`*`) at priority 1 only catches what no HTTPS router (the netbird host above) matched.
resource "kubernetes_manifest" "proxy_passthrough" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "netbird-proxy-passthrough"
      namespace = local.ns
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match    = "HostSNI(`*`)"
        priority = 1
        services = [{
          name             = kubernetes_service_v1.proxy.metadata[0].name
          port             = 8443
          serversTransport = kubernetes_manifest.proxy_protocol.manifest.metadata.name
        }]
      }]
      tls = { passthrough = true }
    }
  }
}
