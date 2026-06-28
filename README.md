# sweetty-instance-template

The deployment and provisioning side of [SweeTTY](https://github.com/adrianmcphee/sweetty),
the multi-protocol honeypot. The product repo builds and ships the binary; this
repo turns a fresh Ubuntu host into a hardened honeypot running a pinned release.

The two are kept separate on purpose, so the honeypot and the way it is operated
can evolve independently. Nothing in here belongs in the product, and nothing in
the product hard-codes how it gets deployed.

## Deploy your own honeypot

This is a GitHub template repository. Each honeypot you run is its own copy, so the
deployment is versioned and reproducible.

1. Click **Use this template** and create a **private** repository. Keep it
   private: it will carry your operator address, your log collector, and your
   instance config.
2. Clone your repo, copy `sweetty.instance.env.example` to `sweetty.instance.env`,
   and fill in the operator address, the release tag to run, and the log
   collector. `.gitignore` keeps the real env out of git by default, so the public
   template cannot leak secrets. In your private repo you may force-add it so the
   honeypot is reproducible from its repo, or keep it local and pass it at provision
   time.
3. On a fresh Ubuntu host (cloud-init can call this for you), provision it:

   ```bash
   sudo INSTANCE_ENV="$PWD/sweetty.instance.env" provision/provision.sh
   ```

4. On the host, deploy a pinned release as the `deploy` user: `make deploy
   TAG=vX.Y.Z` (cloud-init installs the deploy key for you; for a hand-provisioned
   host, add it first, see the provisioning flow below).
5. Reach the portal over the SSH tunnel (as `deploy`) that provisioning prints at
   the end.

For several honeypots, use one private repo per instance, or one repo with a branch
or directory per instance.

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
ssh -L 8443:127.0.0.1:<PORTAL_PORT> deploy@host -p <ADMIN_SSH_PORT>
# then open http://localhost:8443
```

## The HAProxy decision

By default sweetty binds the public honeypot ports directly and there is no
proxy. That is simpler, it is what `provision.sh` sets up, and it keeps the
attacker's real source IP without any extra machinery.

HAProxy is offered as a clearly optional layer for three specific wants:
real-source-IP preservation when you put anything in front of the honeypot, true
zero-downtime blue/green, and TLS termination for the portal. Two rules are
non-negotiable when you use it, and `haproxy/README.md` covers both in full:

- **PROXY protocol to the backend.** sweetty must keep logging the real attacker
  IP, so HAProxy sends the PROXY header and sweetty must be run with PROXY-protocol
  parsing enabled. The two settings are a matched pair.
- **Gentle rate limiting only.** The stick-table limits shed obvious floods and
  nothing more. Heavy upstream rate limiting is wrong for a honeypot: it throws
  away the very intelligence the honeypot exists to collect, because a scanner that
  gets throttled simply leaves. Volumetric protection belongs in nftables and the
  cloud firewall, at the network layer, not as application throttling.

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
