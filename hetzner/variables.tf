variable "name" {
  description = "Name of the existing server to reuse (imported by make hetzner-import)"
  type        = string
  default     = "vm-k3s"
}

variable "server_type" {
  description = "Must match the existing server's type (make hetzner-import prints it); a change resizes it"
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "Image make hetzner-rebuild installs; scripts/bootstrap.sh assumes Ubuntu 24.04"
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Must match the existing server's location; a change would mean a new server"
  type        = string
  default     = "nbg1"
}

variable "admin_user" {
  description = "Sudo user created by scripts/bootstrap.sh; root login is disabled"
  type        = string
  default     = "k3s"
}

variable "ssh_port" {
  description = "Port sshd listens on (key-only auth); 22 is closed"
  type        = number
  default     = 1337
}

variable "enable_backups" {
  description = "Hetzner automatic backups (+20% of the server price)"
  type        = bool
  default     = true
}

variable "dns_zone" {
  description = "Existing Hetzner DNS zone (Console DNS, same project as HCLOUD_TOKEN)"
  type        = string
  default     = "ez-lab.de"
}

variable "pangolin_subdomain" {
  description = "Subdomain for the Pangolin dashboard and Gerbil endpoint"
  type        = string
  default     = "pangolin"
}

variable "public_subdomains" {
  description = "Extra subdomains pointed at the VM, one per Pangolin resource (e.g. [\"blog\"])"
  type        = list(string)
  default     = []
}

variable "dns_ttl" {
  description = "TTL of the managed DNS records in seconds"
  type        = number
  default     = 300
}
