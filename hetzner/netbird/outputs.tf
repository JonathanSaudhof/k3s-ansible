output "public_urls" {
  value = { for k, s in netbird_reverse_proxy_service.app : k => "https://${s.domain}" }
}
