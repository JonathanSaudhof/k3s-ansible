output "dashboard_url" {
  value = local.netbird_url
}

output "management_url" {
  value = local.netbird_url
}

output "owner_email" {
  value = var.owner_email
}

output "owner_password" {
  value     = random_password.owner.result
  sensitive = true
}

output "store_encryption_key" {
  value     = random_bytes.store_encryption_key.base64
  sensitive = true
}
