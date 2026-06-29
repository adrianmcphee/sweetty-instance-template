# sweetty-instance-template

The deployment and provisioning side of [SweeTTY](https://github.com/adrianmcphee/sweetty),
the multi-protocol honeypot. The product repo builds and ships the binary; this
repo turns a fresh Ubuntu host into a hardened honeypot running a pinned release.

The two are kept separate on purpose, so the honeypot and the way it is operated
can evolve independently. Nothing in here belongs in the product, and nothing in
the product hard-codes how it gets deployed.

## Set up a box from scratch

This is a GitHub template repository: click **Use this template**, make a
**private** copy (it will hold your operator address and instance config), and
work from that. Automating this with an agent? The exact, deterministic procedure
is in [`AGENTS.md`](./AGENTS.md); the human walkthrough is below.

### Before you start, you need three things

- A **fresh Ubuntu host** (24.04 or 26.04 LTS, **x86_64**) on its own segment,
  that exists only to be attacked. Nothing real should live near it.
- The **public IP you connect from** (your laptop's egress address, e.g. what
  `curl ifconfig.me` shows). This becomes `OPERATOR_IP`, the only address allowed
  to reach management. It is the address you connect **from**, never the server's
  own IP. A wrong value locks you out and the box has to be rebuilt.
- A **deploy SSH keypair**. You keep the private key; its public key goes on the
  box for the `deploy` user, which is the only login that exists after
  provisioning.

Then pick one path. Both end at the same hardened, running honeypot.

### Path A: cloud-init (hands-off, best for a brand-new VM)

The box provisions and deploys itself on first boot. You paste one file when you
create the VM and never SSH in to set it up.

1. Copy `sweetty.instance.env.example` to `sweetty.instance.env` and fill in
   `OPERATOR_IP` and `RELEASE_TAG` (a published
   [sweetty release](https://github.com/adrianmcphee/sweetty/releases), e.g.
   `v0.1.6`). Leave `TOPOLOGY="haproxy"`, and leave `ADMIN_SSH_PORT` **empty** so
   real SSH lands on a per-instance random port (no fleet-wide tell). The chosen
   port and the exact login + tunnel commands are written to
   `/root/sweetty-access.txt`, which you read from the provider's serial console.
2. Edit `cloud-init/user-data.yaml`: copy those env values into its
   `sweetty.instance.env` block, paste your deploy **public** key into the
   `deploy.pub` block, and set `PROVISION_SHA` to the template commit you reviewed
   (`git rev-parse HEAD`).
3. Create the VM and paste that `user-data.yaml` into the provider's **Cloud-Init /
   User-Data** field. **That field is easy to leave blank, and if you do, nothing
   provisions**: the box comes up as plain Ubuntu. Wait ~3-5 minutes.
4. **Reboot and verify** (below).

### Path B: over SSH (for a host you already have root on)

One script over root SSH does everything. This is what `AGENTS.md` automates.

1. Fill `sweetty.instance.env` as in Path A step 1 (no `PROVISION_SHA` needed).
2. Copy the repo, your env, and your deploy **public** key onto the host:

   ```bash
   rsync -a --exclude='.git' ./ root@HOST:/root/sweetty-instance-template/
   scp sweetty.instance.env root@HOST:/root/sweetty-instance-template/
   scp deploy.pub          root@HOST:/root/deploy.pub
   ```

3. Run the bootstrap as root. It provisions, installs the deploy key, deploys the
   pinned release, and verifies the honeypot is actually serving before it returns:

   ```bash
   ssh root@HOST 'cd /root/sweetty-instance-template && \
     INSTANCE_ENV=$PWD/sweetty.instance.env DEPLOY_PUBKEY=/root/deploy.pub ./bootstrap.sh'
   ```

   Provisioning moves SSH off port 22 and disables root login partway through; your
   running root session survives. `bootstrap.sh` ends by printing the randomized
   admin port and the exact login + tunnel commands (also saved to
   `/root/sweetty-access.txt`); from now on you log in as `deploy` (below).
4. **Reboot and verify** (below).

### Reboot and verify (do this every time)

A honeypot must survive reboots unattended, and a reboot is the cheapest proof
provisioning is sound:

```bash
ssh -p ADMIN_SSH_PORT deploy@HOST 'sudo systemctl reboot'
sleep 60
ssh -p ADMIN_SSH_PORT deploy@HOST \
  'systemctl is-active sweetty-green.service nftables; ss -tln | grep -cE ":(21|22|23|80|443|2323|8080) "'
```

Expect the honeypot slot active, `nftables` active, and the honeypot ports bound.
If a reboot does not come back cleanly, that is a provisioning defect, not a
one-off (the egress firewall must allow the link-local range so cloud-init can
reach the instance metadata service on boot).

### Reach it afterward

- **Admin shell:** `ssh -p ADMIN_SSH_PORT deploy@HOST`, where `ADMIN_SSH_PORT` is
  the randomized port from `/root/sweetty-access.txt` (or the bootstrap output).
  Root login and password auth are off by design; the only door is the `deploy`
  user with your key, firewalled to `OPERATOR_IP`. Port 22 is the honeypot, not
  real SSH.
- **The management console** binds loopback `8888` and is never exposed. Forward it
  over the admin SSH, and use `-fN` so it is a tunnel, not a login shell:

  ```bash
  ssh -fN -L 8888:127.0.0.1:8888 deploy@HOST -p ADMIN_SSH_PORT
  # then open http://localhost:8888   (stop it later: pkill -f '8888:127.0.0.1:8888')
  ```

- **Update later:** `ssh -p ADMIN_SSH_PORT deploy@HOST`, then
  `cd sweetty-instance-template && make deploy TAG=vX.Y.Z` (pinned, verified,
  blue/green).

For several honeypots, use one private repo per instance, or one repo with a
branch or directory per instance.

## What you get

- A fresh-host provisioning flow: cloud-init plus an idempotent `provision.sh`
  (and an optional Terraform example) that create the unprivileged `sweetty`
  user, lay out `/opt/sweetty`, install the systemd slot units, and harden the
  box.
- An nftables firewall that opens the attack surface to the world, restricts
  management to one operator address, and denies the honeypot any egress.
- Intrusion-detection tripwires (auditd, optional osquery) tuned to alarm only on
  events the honeypot is contractually unable to produce.
- Off-host, append-only log shipping.
- An optional HAProxy edge for source-IP preservation and zero-downtime deploys.
- A pinned, checksum-verified blue/green deploy built on
  [slotdeploy](https://github.com/adrianmcphee/slotdeploy).

## Threat model: assume-escape

The whole design follows from one premise. A honeypot is an attractant you
deliberately expose to attack, so plan for the worst case and make it boring.

SweeTTY itself never executes attacker input. Commands are emulated in-process,
downloads are theatre (the URL is logged, never fetched), and files an attacker
"creates" live in an in-memory overlay that evaporates on disconnect. That is the
product's safety boundary, and it is strong.

This repo does not rely on it. The host treats the `sweetty` user as **already
hostile**, and every control here is built for the world where the deception
boundary has somehow been crossed:

- The service runs as an unprivileged user with no shell, under systemd
  hardening that makes the filesystem read-only except its log directory,
  hides the real `/proc`, strips capabilities to the single one it needs to bind
  low ports, and filters its system calls.
- The firewall denies the `sweetty` user all outbound traffic and logs any
  attempt, because a honeypot that calls out is either compromised or being used
  as a relay against someone else.
- The tripwires alarm on the three things the honeypot can never legitimately do:
  spawn a child, open an outbound connection, or write outside its log. There is
  no benign version of these events on this host, so the alarms are near
  zero false positive.
- The log is shipped off-host continuously and kept append-only on disk, so the
  intelligence survives even if the box does not.

In short: the product is trustworthy, and the host is built as though it is not.

## Layout

```
sweetty-instance-template/
├── sweetty.instance.env.example   Single source of truth for one host (copy, fill, gitignored)
├── Makefile                       Local gates plus provision/deploy/rollback/status wrappers
├── cloud-init/
│   └── user-data.yaml             First-boot provisioning
├── provision/
│   ├── provision.sh               Idempotent host bootstrap
│   ├── config.json                sweetty config (direct topology)
│   ├── render-nftables.sh         Renders the firewall from the instance env
│   ├── nftables/sweetty.nft.template
│   ├── systemd/                   sweetty-blue.service, sweetty-green.service
│   ├── sudoers/                   Narrow deploy-user grants
│   └── sysctl/                    Kernel and network hardening
├── ids/
│   ├── auditd/sweetty.rules       Primary kernel tripwires
│   ├── osquery/                   Optional pack and config
│   └── README.md                  Why these are zero-false-positive alarms
├── logging/
│   ├── rsyslog/60-sweetty.conf    Off-host shipping (default)
│   ├── vector.toml                Off-host shipping (JSON-native alternative)
│   └── README.md                  Append-only rotation caveat
├── haproxy/
│   ├── haproxy.cfg                Optional TCP edge
│   ├── config.haproxy.json        sweetty config for the HAProxy topology
│   └── README.md                  PROXY protocol, gentle limits, the decision
├── deploy/
│   ├── deploy.sh                  Pinned, verified, blue/green deploy
│   ├── slotdeploy.yaml            slotdeploy commands runtime
│   └── README.md
└── terraform/                     Optional single-host example
```

## Provisioning flow

1. Create an isolated Ubuntu host, on its own segment, that exists only to be
   attacked. Nothing real should live near it.
2. Copy `sweetty.instance.env.example` to `sweetty.instance.env` and fill it in:
   the operator address, the admin SSH port, the release tag to run, the DNS
   resolvers, and the log endpoint. This file is the single source of truth and
   is gitignored. Set `OPERATOR_IP` to the address you actually connect from:
   admin SSH is firewalled to it alone, so a wrong value locks you out and the box
   has to be rebuilt. The renderer refuses an all-internet wildcard, so you cannot
   accidentally open management to the world.
3. Run provisioning. cloud-init does this at first boot; to run it by hand:

   ```bash
   sudo INSTANCE_ENV=sweetty.instance.env provision/provision.sh
   ```

   It creates the `sweetty` and `deploy` users, lays out `/opt/sweetty`, installs
   the two slot units, moves real SSH off port 22 (so the honeypot can bind 22),
   loads the nftables firewall and sysctl hardening, installs the auditd
   tripwires and optional osquery pack, wires up off-host log shipping, and makes
   `sweetty.log` append-only. It is idempotent; run it again any time.

   When cloud-init runs it at first boot, it first fetches this provisioning code
   and verifies it against a pinned commit before running any of it as root, since
   the whole perimeter comes from here. Set `PROVISION_SHA` (and `PROVISION_REF`,
   preferably an immutable tag) in the cloud-init instance env to the commit you
   reviewed; on a mismatch the box powers itself off instead of provisioning from an
   unknown tree.
4. Add the deploy public key to the `deploy` user, then deploy a release. The
   host has no binary until you do, on purpose.

Real SSH is on a randomized, http-like `ADMIN_SSH_PORT` (8088 and friends, picked
per instance so it blends in as a web service with no fixed admin-port tell) and
reachable only from the operator address. Port 22 is the honeypot. If you
provision over an existing port-22 session, reconnect on the admin port once
`provision.sh` restarts sshd.

The management portal is never exposed. It binds loopback, and you reach it by
forwarding the SSH port to it, so SSH key auth is the only front door and the
portal itself needs no login. You log in as the `deploy` user, the only account
with a shell and the only key provisioning installs (root login and password auth
are disabled), so hold its private key:

```
ssh -L 8888:127.0.0.1:8888 deploy@host -p <ADMIN_SSH_PORT>
# then open http://localhost:8888
```

## The HAProxy edge

The default topology (`TOPOLOGY="haproxy"`) puts a transparent HAProxy TCP edge in
front of the honeypot ports. `provision.sh` installs and starts it. It is
invisible to attackers (a plain TCP passthrough, no termination) and does three
jobs: preserves the real attacker source IP, sheds obvious connection floods, and
exposes its stats console inside the management console. Choose `TOPOLOGY="direct"`
to skip it and have sweetty bind the public ports itself.

Two rules are non-negotiable, and `haproxy/README.md` covers both in full:

- **PROXY protocol to the backend.** sweetty must keep logging the real attacker
  IP, so HAProxy sends the PROXY header and sweetty runs with PROXY-protocol
  parsing enabled (`config.haproxy.json` sets this). The two settings are a
  matched pair.
- **Gentle rate limiting only.** The stick-table limits shed obvious floods and
  nothing more. Heavy upstream rate limiting is wrong for a honeypot: it throws
  away the very intelligence the honeypot exists to collect, because a scanner that
  gets throttled simply leaves. Volumetric protection belongs in nftables and the
  cloud firewall, at the network layer, not as application throttling.

When the edge sheds a flood, the `sweetty hapwatch` helper (a `sweetty-hapwatch`
systemd unit provisioning installs) reads HAProxy's stick-table over its local
admin socket and logs a `FLOOD_BLOCKED` event, so the rate-limiting shows up in
the same live feed as everything else. The HAProxy stats page is bound to loopback
and reverse-proxied by the portal at `/dashboard/console/haproxy/`, reached over
the same SSH tunnel with no second login.

## Deploy flow

Deploys are pinned and verified. There is no implicit `latest`, anywhere. Run them
on the host as the `deploy` user (it uses the narrow sudo grants provisioning set
up), or from CI holding the deploy key.

```bash
deploy/deploy.sh v0.3.0
```

This pulls `sweetty_<ver>_linux_<arch>.tar.gz` and `checksums.txt` from the
product repo's GitHub Releases for that exact tag, verifies the artifact with
`sha256sum` before installing anything, drops the binary into the inactive slot,
and hands off to slotdeploy to start the new slot, health-check it, stop the old
one, and flip the active marker. Roll back with
`slotdeploy rollback --config deploy/slotdeploy.yaml`; the previous binary is
still on disk, so it is a switch, not a rebuild.

The honeypot binds fixed low ports, which a single process must own, so the
default direct topology trades a sub-second cutover gap for never running two
attack surfaces at once. A honeypot can miss a few connections during a deploy; it
must not expose a half-bound instance. Choose the HAProxy topology if you need
genuinely zero-downtime deploys. Full detail in `deploy/README.md`.

## Conventions

- **No AI attribution in commits.** No `Co-Authored-By`, no "Generated with",
  nothing. The commit-msg hook and CI enforce it.
- **No em dashes**, in any file or any commit message. The hook rejects them.
- **Atomic, semantic commits.** One logical change each.
- **Secrets and captured data never get committed.** Logs, keys, certs, real
  `*.env`, terraform state, and `*.tfvars` (except the examples) are gitignored.

Run `make check` before committing: it checks for em dashes, shellchecks the
scripts, and syntax-checks the firewall ruleset.

## A word of caution

A honeypot ends up on the radar of the people you are studying. Run it on a host
you are prepared to lose, isolated from anything real, with egress constrained,
and make sure you are authorised to operate it on the network where you deploy
it. Everything the attacker sees is fake; the box is still genuinely exposed.
