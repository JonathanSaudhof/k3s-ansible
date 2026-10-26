# The existing server and its primary IPs are imported (make hetzner-import), not created.
# auto_delete = false keeps the IPs, and with them the DNS records, if the server ever goes away.
resource "hcloud_primary_ip" "ipv4" {
  name        = "${var.name}-ipv4"
  type        = "ipv4"
  location    = var.location
  auto_delete = false
}

resource "hcloud_primary_ip" "ipv6" {
  name        = "${var.name}-ipv6"
  type        = "ipv6"
  location    = var.location
  auto_delete = false
}

# Only what NetBird and SSH need. The k3s API (6443) stays closed; reach it with `make hetzner-tunnel`.
# 22 is open for the rebuild -> bootstrap step only: a fresh image listens there (root, key only)
# until bootstrap.sh moves sshd to ssh_port, after which nothing listens on 22.
locals {
  anywhere = ["0.0.0.0/0", "::/0"]
  inbound = {
    ssh           = { protocol = "tcp", port = tostring(var.ssh_port) }
    ssh-bootstrap = { protocol = "tcp", port = "22" }
    http          = { protocol = "tcp", port = "80" }
    https         = { protocol = "tcp", port = "443" }  # dashboard, management, signal, relay, reverse proxy
    stun          = { protocol = "udp", port = "3478" } # NetBird STUN, can't go through Traefik
  }
}

resource "hcloud_firewall" "k3s" {
  name = "${var.name}-public"

  dynamic "rule" {
    for_each = local.inbound
    content {
      description = rule.key
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = local.anywhere
    }
  }

  rule {
    description = "icmp"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = local.anywhere
  }
}

resource "hcloud_server" "k3s" {
  name         = var.name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  firewall_ids = [hcloud_firewall.k3s.id]
  backups      = var.enable_backups

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6.id
  }

  # The OS is (re)installed by terraform_data.rebuild/bootstrap below, not by replacing the server, so
  # the image and creation-time keys/user_data of the imported server are not this resource's concern.
  # prevent_destroy stops a config mismatch (e.g. location) from replacing the reused server.
  lifecycle {
    ignore_changes  = [image, ssh_keys, user_data]
    prevent_destroy = true
  }
}

# The zone already exists (home records live in it too), so it's only looked up. Managed here, A + AAAA
# to the VM:
# - netbird: dashboard + management (Traefik)
# - *: the NetBird reverse proxy's domain (NB_PROXY_DOMAIN = the zone), so every service in
#   ../apps.json is <name>.<zone> without a record of its own. Names with an explicit record (the
#   apex, coolify, ...) are not covered by the wildcard. `*/A` existed before and was imported:
#   tofu import 'hcloud_zone_rrset.public["*/A"]' 'ez-lab.de/*/A'
data "hcloud_zone" "main" {
  name = var.dns_zone
}

locals {
  host_names = toset([var.netbird_subdomain, "*"])
  dns_records = merge([
    for n in local.host_names : {
      "${n}/A" = { name = n, type = "A", value = hcloud_primary_ip.ipv4.ip_address }
      # An IPv6 primary IP is a /64; the server answers on its ::1 address.
      "${n}/AAAA" = { name = n, type = "AAAA", value = cidrhost(hcloud_primary_ip.ipv6.ip_network, 1) }
    }
  ]...)
}

resource "hcloud_zone_rrset" "public" {
  for_each = local.dns_records
  zone     = data.hcloud_zone.main.name
  name     = each.value.name
  type     = each.value.type
  ttl      = var.dns_ttl
  records  = [{ value = each.value.value }]
}

# --- OS install + k3s --------------------------------------------------------------------------
# Bump rebuild_generation to WIPE the server and reinstall var.image; 0 never rebuilds, so the first
# apply on an already bootstrapped server doesn't wipe it.
resource "terraform_data" "rebuild" {
  count            = var.rebuild_generation > 0 ? 1 : 0
  triggers_replace = [var.rebuild_generation, var.image]

  provisioner "local-exec" {
    command = "${path.module}/../scripts/hcloud.sh rebuild ${hcloud_server.k3s.name} --yes"
    environment = {
      IMAGE    = var.image
      SSH_PORT = tostring(var.ssh_port)
    }
  }

  # The rebuild waits for port 22, which the firewall must already allow.
  depends_on = [hcloud_firewall.k3s]
}

# Re-runs after every rebuild and whenever bootstrap.sh changes. bootstrap.sh is idempotent; it goes in
# as root on 22 on a fresh image and as admin_user on ssh_port afterwards. Ends with the kubeconfig.
resource "terraform_data" "bootstrap" {
  triggers_replace = [
    one(terraform_data.rebuild[*].id),
    filesha256("${path.module}/../scripts/bootstrap.sh"),
    var.acme_email,
  ]

  provisioner "local-exec" {
    command = "${path.module}/../scripts/hcloud.sh bootstrap ${hcloud_server.k3s.name}"
    environment = {
      ADMIN_USER     = var.admin_user
      SSH_PORT       = tostring(var.ssh_port)
      ACME_EMAIL     = var.acme_email
      KUBECONFIG_OUT = abspath("${path.module}/../../kubeconfig-hetzner")
      API_PORT       = tostring(var.api_tunnel_port)
    }
  }
}
