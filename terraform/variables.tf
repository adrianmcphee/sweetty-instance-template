variable "do_token" {
  description = "DigitalOcean API token. Pass via TF_VAR_do_token or a tfvars file, never commit it."
  type        = string
  sensitive   = true
}

variable "hostname" {
  description = "Droplet name."
  type        = string
  default     = "sweetty-sensor"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "ams3"
}

variable "droplet_size" {
  description = "Droplet size slug. A honeypot is light; the smallest current size is plenty."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "ssh_key_fingerprints" {
  description = "Fingerprints of SSH keys already uploaded to DigitalOcean, for first-boot root access."
  type        = list(string)
  default     = []
}

variable "operator_cidr" {
  description = "The only source allowed to reach management (real SSH and the portal). A single host as a.b.c.d/32 or a range."
  type        = string
}

variable "admin_ssh_port" {
  description = "Non-standard port the real sshd listens on (port 22 is the honeypot). Must match ADMIN_SSH_PORT in the cloud-init env."
  type        = string
  default     = "61022"
}

variable "log_port" {
  description = "Port of the off-host log collector, allowed outbound. Must match the port in LOG_ENDPOINT."
  type        = string
  default     = "6514"
}
