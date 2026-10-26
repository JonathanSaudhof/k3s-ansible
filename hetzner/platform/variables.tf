variable "owner_email" {
  description = "Email of the NetBird admin the server creates on first start (set in terraform.tfvars)"
  type        = string

  # Catches stray terminal escapes from typing it at tofu's interactive prompt.
  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+$", var.owner_email))
    error_message = "owner_email must be a plain email address (check for invisible characters)."
  }
}

variable "netbird_version" {
  description = "Tag of netbirdio/netbird-server and netbirdio/reverse-proxy (released together)"
  type        = string
  default     = "0.81.4"
}

variable "dashboard_version" {
  description = "Tag of netbirdio/dashboard"
  type        = string
  default     = "v2.95.0"
}

variable "pod_cidr" {
  description = "k3s pod network; Traefik connects from it, so the server and proxy trust its forwarded client IPs"
  type        = string
  default     = "10.42.0.0/16"
}
