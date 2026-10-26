output "public_ipv4" {
  value = hcloud_primary_ip.ipv4.ip_address
}

output "public_ipv6" {
  value = cidrhost(hcloud_primary_ip.ipv6.ip_network, 1)
}

output "ssh_port" {
  value = var.ssh_port
}

output "admin_user" {
  value = var.admin_user
}

output "netbird_host" {
  value = "${var.netbird_subdomain}.${var.dns_zone}"
}

# NB_PROXY_DOMAIN: services are <name>.<zone>, through the `*` record.
output "proxy_host" {
  value = var.dns_zone
}

output "dns_zone" {
  value = var.dns_zone
}
