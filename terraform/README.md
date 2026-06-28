# Terraform (optional)

A minimal, single-file example that stands up one honeypot host. It is optional:
if you create hosts another way, ignore this directory and feed
`cloud-init/user-data.yaml` to your provider directly.

It provisions one DigitalOcean droplet plus a cloud firewall, hands the droplet
the cloud-init file, and lets first-boot provisioning do the rest. Swapping in
another provider is a small edit (the droplet and firewall resources); the
cloud-init contract is provider-independent.

## Use

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit it (gitignored)
export TF_VAR_do_token="dop_v1_..."            # keep the token out of files
# Edit ../cloud-init/user-data.yaml first: operator IP, release tag, log endpoint.
terraform init
terraform apply
```

## Two firewalls, on purpose

The cloud firewall here and the on-host nftables ruleset are both present by
design, and they do different jobs:

- The **cloud firewall** is the volumetric front line: it absorbs floods at the
  provider edge, which is where that belongs, and never throttles application
  traffic.
- The **on-host nftables ruleset** is the authority on policy: it denies the
  honeypot user all egress, logs surprise outbound attempts, and is what you can
  reason about precisely.

Keep both. The cloud firewall is coarse and the host ruleset is exact; together
they are belt and braces.

## Keep state out of git

`.gitignore` already excludes `*.tfstate*`, `.terraform/`, and `*.tfvars` (except
the example). Terraform state can contain sensitive values; do not commit it.
Use a remote backend for anything beyond a throwaway.
