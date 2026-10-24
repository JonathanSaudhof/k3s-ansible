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

output "pangolin_host" {
  value = "${var.pangolin_subdomain}.${var.dns_zone}"
}
