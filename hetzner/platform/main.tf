# Self-hosted NetBird on the Hetzner k3s: the combined netbird-server (management, signal, relay,
# STUN, embedded IdP), the dashboard and the reverse proxy, behind the bundled Traefik. Mirrors the
# docker-compose that NetBird's getting-started.sh renders, translated to Kubernetes.
locals {
  ns          = kubernetes_namespace_v1.netbird.metadata[0].name
  netbird     = data.terraform_remote_state.infra.outputs.netbird_host
  proxy       = data.terraform_remote_state.infra.outputs.proxy_host
  netbird_url = "https://${local.netbird}"
}

resource "kubernetes_namespace_v1" "netbird" {
  metadata {
    name = "netbird"
  }
}

# --- secrets, generated once and kept in state ----------------------------------------------------
resource "random_bytes" "relay_auth_secret" {
  length = 32
}

# The store encryption key encrypts tokens and keys in the sqlite store: losing it makes the
# database unreadable. Back it up (make hetzner-netbird-secrets).
resource "random_bytes" "store_encryption_key" {
  length = 32
}

resource "random_bytes" "session_cookie_key" {
  length = 32
}

# Only used on the very first start, to create the owner account; change it in the dashboard after.
resource "random_password" "owner" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "config" {
  metadata {
    name      = "netbird-server-config"
    namespace = local.ns
  }

  data = {
    "config.yaml" = yamlencode({
      server = {
        listenAddress      = ":80" # TLS ends at Traefik
        exposedAddress     = "${local.netbird_url}:443"
        stunPorts          = [3478]
        metricsPort        = 9090
        healthcheckAddress = ":9000"
        logLevel           = "info"
        logFile            = "console"
        authSecret         = random_bytes.relay_auth_secret.base64
        dataDir            = "/var/lib/netbird"
        auth = {
          issuer                     = "${local.netbird_url}/oauth2"
          signKeyRefreshEnabled      = true
          sessionCookieEncryptionKey = random_bytes.session_cookie_key.base64
          dashboardRedirectURIs      = ["${local.netbird_url}/nb-auth", "${local.netbird_url}/nb-silent-auth"]
          cliRedirectURIs            = ["http://localhost:53000/"]
          owner = {
            email = var.owner_email
            # NetBird hands this to Dex as the password hash, so it must be bcrypt, not plain text.
            password = random_password.owner.bcrypt_hash
          }
        }
        reverseProxy = {
          trustedHTTPProxies = [var.pod_cidr]
        }
        store = {
          engine        = "sqlite"
          encryptionKey = random_bytes.store_encryption_key.base64
        }
      }
    })
  }
}

# --- netbird-server -------------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "server_data" {
  metadata {
    name      = "netbird-server-data"
    namespace = local.ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  # local-path binds only once the pod is scheduled.
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "server" {
  metadata {
    name      = "netbird-server"
    namespace = local.ns
  }

  spec {
    replicas = 1
    # sqlite on a RWO volume: never two servers at once.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "netbird-server" }
    }

    template {
      metadata {
        labels = { app = "netbird-server" }
        annotations = {
          # Restart on config changes; the server reads config.yaml only at start.
          "checksum/config" = sha256(kubernetes_secret_v1.config.data["config.yaml"])
        }
      }

      spec {
        container {
          name  = "netbird-server"
          image = "netbirdio/netbird-server:${var.netbird_version}"
          args  = ["--config", "/etc/netbird/config.yaml"]

          port {
            name           = "http"
            container_port = 80
          }
          # hostPort rather than a ServiceLB Service: STUN answers with the source address it sees,
          # which a Service's SNAT would replace with a cluster IP.
          port {
            name           = "stun"
            container_port = 3478
            host_port      = 3478
            protocol       = "UDP"
          }

          readiness_probe {
            tcp_socket {
              port = 80
            }
            period_seconds = 5
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/netbird"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/netbird"
            read_only  = true
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.server_data.metadata[0].name
          }
        }
        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "server" {
  metadata {
    name      = "netbird-server"
    namespace = local.ns
  }
  spec {
    selector = { app = "netbird-server" }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

# --- dashboard ------------------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "dashboard" {
  metadata {
    name      = "netbird-dashboard"
    namespace = local.ns
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "netbird-dashboard" }
    }

    template {
      metadata {
        labels = { app = "netbird-dashboard" }
      }

      spec {
        container {
          name  = "dashboard"
          image = "netbirdio/dashboard:${var.dashboard_version}"

          dynamic "env" {
            for_each = {
              NETBIRD_MGMT_API_ENDPOINT      = local.netbird_url
              NETBIRD_MGMT_GRPC_API_ENDPOINT = local.netbird_url
              AUTH_AUDIENCE                  = "netbird-dashboard"
              AUTH_CLIENT_ID                 = "netbird-dashboard"
              AUTH_CLIENT_SECRET             = ""
              AUTH_AUTHORITY                 = "${local.netbird_url}/oauth2"
              USE_AUTH0                      = "false"
              AUTH_SUPPORTED_SCOPES          = "openid profile email groups"
              AUTH_REDIRECT_URI              = "/nb-auth"
              AUTH_SILENT_REDIRECT_URI       = "/nb-silent-auth"
              NGINX_SSL_PORT                 = "443"
              LETSENCRYPT_DOMAIN             = "none" # TLS ends at Traefik
            }
            content {
              name  = env.key
              value = env.value
            }
          }

          port {
            name           = "http"
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "dashboard" {
  metadata {
    name      = "netbird-dashboard"
    namespace = local.ns
  }
  spec {
    selector = { app = "netbird-dashboard" }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}
