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

# Only what Pangolin and SSH need. 22 and the k3s API (6443) stay closed; reach the API with
# `make hetzner-tunnel`.
locals {
  anywhere = ["0.0.0.0/0", "::/0"]
  inbound = {
    ssh       = { protocol = "tcp", port = tostring(var.ssh_port) }
    http      = { protocol = "tcp", port = "80" }
    https     = { protocol = "tcp", port = "443" }
    wg-sites  = { protocol = "udp", port = "51820" } # Gerbil: Newt sites
    wg-client = { protocol = "udp", port = "21820" } # Gerbil: Pangolin clients
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

  # The OS is (re)installed by `make hetzner-rebuild` + `make hetzner-bootstrap`, not by tofu, so the
  # image and creation-time keys/user_data of the imported server are not tofu's concern.
  # prevent_destroy stops a config mismatch (e.g. location) from replacing the reused server.
  lifecycle {
    ignore_changes  = [image, ssh_keys, user_data]
    prevent_destroy = true
  }
}

# The zone already exists (home records like auth/affine live in it too), so it's only looked up.
# Only the names below are managed; there's deliberately no wildcard.
data "hcloud_zone" "main" {
  name = var.dns_zone
}

locals {
  dns_names = toset(concat([var.pangolin_subdomain], var.public_subdomains))
  dns_records = merge([
    for n in local.dns_names : {
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
