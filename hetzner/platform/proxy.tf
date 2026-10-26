# NetBird reverse proxy: publishes the services configured in ../netbird as <name>.<zone> (infra's `*`
# record). It gets TLS passthrough from Traefik and does its own ACME, one certificate per service.

# The proxy authenticates to management with a token only the server's admin CLI can mint, and which
# is shown once. It goes straight into a Secret, never into tofu state; delete the Secret to re-mint.
resource "terraform_data" "proxy_token" {
  # A new namespace (e.g. after a rebuild) means a new server database and no Secret yet.
  triggers_replace = [kubernetes_namespace_v1.netbird.metadata[0].uid]
  depends_on       = [kubernetes_deployment_v1.server]

  provisioner "local-exec" {
    environment = { KUBECONFIG = local.kubeconfig }
    command     = <<-EOT
      set -euo pipefail
      k="kubectl -n ${local.ns}"
      $k get secret netbird-proxy-token >/dev/null 2>&1 && exit 0
      token=$($k exec deploy/netbird-server -- /go/bin/netbird-server admin token create \
        --name hetzner-proxy --config /etc/netbird/config.yaml | awk '/^Token:/ {print $2}')
      test -n "$token" || { echo "admin token create returned no token" >&2; exit 1; }
      $k create secret generic netbird-proxy-token --from-literal=NB_PROXY_TOKEN="$token"
    EOT
    interpreter = ["bash", "-c"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "proxy_certs" {
  metadata {
    name      = "netbird-proxy-certs"
    namespace = local.ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = { storage = "128Mi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "proxy" {
  metadata {
    name      = "netbird-proxy"
    namespace = local.ns
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # RWO certificate volume
    }
    selector {
      match_labels = { app = "netbird-proxy" }
    }

    template {
      metadata {
        labels = { app = "netbird-proxy" }
      }

      spec {
        container {
          name  = "proxy"
          image = "netbirdio/reverse-proxy:${var.netbird_version}"

          dynamic "env" {
            for_each = {
              # In-cluster, so no hairpin through the public IP.
              NB_PROXY_MANAGEMENT_ADDRESS    = "http://${kubernetes_service_v1.server.metadata[0].name}.${local.ns}.svc:80"
              NB_PROXY_ALLOW_INSECURE        = "true"
              NB_PROXY_DOMAIN                = local.proxy
              NB_PROXY_ADDRESS               = ":8443"
              NB_PROXY_CERTIFICATE_DIRECTORY = "/certs"
              NB_PROXY_ACME_CERTIFICATES     = "true"
              NB_PROXY_ACME_CHALLENGE_TYPE   = "tls-alpn-01"
              NB_PROXY_FORWARDED_PROTO       = "https"
              # Traefik prepends PROXY protocol v2 (ServersTransportTCP pp-v2) to keep client IPs.
              NB_PROXY_PROXY_PROTOCOL  = "true"
              NB_PROXY_TRUSTED_PROXIES = var.pod_cidr
            }
            content {
              name  = env.key
              value = env.value
            }
          }
          env_from {
            secret_ref {
              name = "netbird-proxy-token"
            }
          }

          port {
            name           = "tls"
            container_port = 8443
          }

          volume_mount {
            name       = "certs"
            mount_path = "/certs"
          }
        }

        volume {
          name = "certs"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.proxy_certs.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [terraform_data.proxy_token]
}

resource "kubernetes_service_v1" "proxy" {
  metadata {
    name      = "netbird-proxy"
    namespace = local.ns
  }
  spec {
    selector = { app = "netbird-proxy" }
    port {
      name        = "tls"
      port        = 8443
      target_port = "tls"
    }
  }
}
