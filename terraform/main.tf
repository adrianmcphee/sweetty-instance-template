# OPTIONAL minimal Terraform for standing up one SweeTTY host.
#
# This is an example, not a requirement. If you already create hosts another way
# (console, Ansible, another IaC tool), skip this directory and paste
# cloud-init/user-data.yaml into your provider's user-data field instead.
#
# It provisions a single DigitalOcean droplet and hands it the cloud-init file,
# which creates the users, lays out /opt/sweetty, loads the firewall, and so on.
# Edit cloud-init/user-data.yaml (operator IP, release tag, log endpoint) before
# applying; that file is the single source of truth for the host config.
#
# A cloud firewall is attached as the volumetric front line (the honeypot ports
# open to the world, management restricted to the operator), which is where
# edge DDoS protection belongs rather than in any application-level rate limit.

terraform {
  required_version = ">= 1.5"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "sweetty" {
  name      = var.hostname
  region    = var.region
  size      = var.droplet_size
  image     = "ubuntu-24-04-x64"
  ssh_keys  = var.ssh_key_fingerprints
  user_data = file("${path.module}/../cloud-init/user-data.yaml")

  # A honeypot is a box you are prepared to lose. Keep it isolated and tagged so
  # it never gets mistaken for something that serves real traffic.
  tags = ["sweetty", "honeypot", "isolated"]
}

resource "digitalocean_firewall" "sweetty" {
  name        = "${var.hostname}-fw"
  droplet_ids = [digitalocean_droplet.sweetty.id]

  # The attack surface: open to the world. This is the product.
  dynamic "inbound_rule" {
    for_each = ["21", "22", "23", "80", "443", "2323", "8080"]
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.value
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }

  # Management: real SSH and the portal, reachable only from the operator.
  inbound_rule {
    protocol         = "tcp"
    port_range       = var.admin_ssh_port
    source_addresses = [var.operator_cidr]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8443"
    source_addresses = [var.operator_cidr]
  }

  # Egress is intentionally narrow. The host needs DNS, the release pull (443),
  # and the log endpoint; the honeypot user itself gets nothing (nftables denies
  # it on the host). Cloud firewalls are coarse, so the on-host nftables ruleset
  # remains the authority; this is defence in depth.
  outbound_rule {
    protocol              = "udp"
    port_range            = "53"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = "53"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = "443"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = var.log_port
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
