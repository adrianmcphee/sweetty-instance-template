output "sweetty_ipv4" {
  description = "Public IPv4 of the honeypot host."
  value       = digitalocean_droplet.sweetty.ipv4_address
}

output "admin_ssh" {
  description = "How to reach real SSH (allowed only from operator_cidr)."
  value       = "ssh -p ${var.admin_ssh_port} <user>@${digitalocean_droplet.sweetty.ipv4_address}"
}

output "portal_url" {
  description = "Management portal (allowed only from operator_cidr)."
  value       = "https://${digitalocean_droplet.sweetty.ipv4_address}:8443"
}
