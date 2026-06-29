# AGENTS.md - bringing up a SweeTTY box, for an automated agent

This is the deterministic procedure for an agent (or a human who wants an exact
script) to turn a fresh host into a running, hardened SweeTTY honeypot over root
SSH. It is the machine-readable form of the "Path B: over SSH" walkthrough in
[README.md](./README.md). Follow it in order. Do not improvise the firewall or the
SSH cutover; the safety rail in step 4 exists because a wrong operator address
locks everyone out of the box.

## Preconditions

- Root SSH to a **fresh Ubuntu 24.04/26.04, x86_64** host that exists only to be
  attacked. Confirm `ssh root@HOST true` works and `uname -m` is `x86_64`.
- A **deploy SSH keypair**. You hold the private key; you will install the public
  key (`deploy.pub`) on the box. Never put a private key on the box.
- A **pinned release tag** that exists at
  https://github.com/adrianmcphee/sweetty/releases (e.g. `v0.1.6`). Never `latest`.

## Step 1 - Determine OPERATOR_IP (do not guess)

`OPERATOR_IP` is the single public IP **the human operator will connect from**,
and admin SSH is firewalled to it alone. A wrong value bricks management.

If you are running from the operator's own machine/network, the host already sees
that address as the source of your root session - read it back rather than
inventing it, then confirm with the operator:

```bash
ssh root@HOST 'echo "${SSH_CONNECTION%% *}"'   # first field = operator's public IP
```

If you are not on the operator's network (e.g. a cloud runner), you must be told
the operator's IP explicitly. Do not substitute your own egress IP.

## Step 2 - Stage the repo, env, and deploy key onto the host

Render `sweetty.instance.env` from `sweetty.instance.env.example` with these
values, then copy everything up:

- `OPERATOR_IP` from step 1
- `RELEASE_TAG` = the pinned tag
- `ADMIN_SSH_PORT=""` - leave empty so provisioning randomizes the real-SSH port
  (no fleet-wide tell). You will read the chosen port back in step 6.
- `TOPOLOGY="haproxy"` (default), `PORTAL_PORT="8888"`
- `DNS_RESOLVERS`, and `LOG_ENDPOINT`/`LOG_TRANSPORT` if shipping logs off-host

```bash
rsync -a --exclude='.git' ./ root@HOST:/root/sweetty-instance-template/
scp sweetty.instance.env root@HOST:/root/sweetty-instance-template/sweetty.instance.env
scp deploy.pub          root@HOST:/root/deploy.pub
```

## Step 3 - Sanity-check before you change the perimeter

```bash
ssh root@HOST 'cd /root/sweetty-instance-template && \
  grep -E "^(OPERATOR_IP|RELEASE_TAG|ADMIN_SSH_PORT|TOPOLOGY)=" sweetty.instance.env'
```

Confirm `OPERATOR_IP` is the operator's address and `ADMIN_SSH_PORT=""`.

## Step 4 - Arm the failsafe (REQUIRED before provisioning)

Provisioning moves SSH off port 22, disables root login, and firewalls admin to
`OPERATOR_IP`. If that address is wrong, you finish provisioning and then cannot
get back in. Arm a dead-man's switch first: a transient timer that, unless you
disarm it, reverts SSH to root-on-22 and flushes the firewall so you can recover.

```bash
ssh root@HOST 'rm -f /tmp/sweetty-failsafe-disarm; \
  systemd-run --unit=sweetty-failsafe --on-active=20min --timer-property=AccuracySec=1s \
  /bin/sh -c "[ -e /tmp/sweetty-failsafe-disarm ] && exit 0; \
    nft flush ruleset 2>/dev/null; \
    rm -f /etc/ssh/sshd_config.d/00-sweetty.conf; \
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; true"'
```

You disarm it in step 6, only after confirming you can still get in.

## Step 5 - Bootstrap (provision + deploy key + first release + verify)

One root command does everything and refuses to "succeed" unless the honeypot is
actually serving. The first deploy runs **as the deploy user** so nothing
root-owned is left in its workspace:

```bash
ssh root@HOST 'cd /root/sweetty-instance-template && \
  INSTANCE_ENV=$PWD/sweetty.instance.env DEPLOY_PUBKEY=/root/deploy.pub ./bootstrap.sh'
```

It ends by printing the randomized admin port and the exact login + tunnel
commands. If it prints `VERIFY FAILED`, stop and read the output; do not disarm.

## Step 6 - Confirm access, then disarm

Read the chosen port and prove the operator's real path works **before** removing
the safety rail:

```bash
PORT=$(ssh root@HOST 'sed -n "s/^ADMIN_SSH_PORT=\"\\(.*\\)\"/\\1/p" /root/sweetty-instance-template/sweetty.instance.env')
ssh -p "$PORT" -o ConnectTimeout=10 deploy@HOST 'echo deploy-login-ok && systemctl is-active "sweetty-$(cat /opt/sweetty/.active-slot)".service'
```

Only if that returns `deploy-login-ok` and `active`, disarm:

```bash
ssh -p "$PORT" deploy@HOST 'sudo touch /tmp/sweetty-failsafe-disarm; sudo systemctl stop sweetty-failsafe.timer 2>/dev/null; true'
```

If you could **not** log in as `deploy`, the operator IP or key is wrong: let the
failsafe fire (or trigger recovery via the provider console), fix the value, and
redo from step 2. Never disarm a box you cannot get into.

## Step 7 - Reboot and verify durability (REQUIRED)

A honeypot must survive an unattended reboot. Prove it:

```bash
ssh -p "$PORT" deploy@HOST 'sudo systemctl reboot'; sleep 75
ssh -p "$PORT" deploy@HOST \
  'systemctl is-active "sweetty-$(cat /opt/sweetty/.active-slot)".service nftables; \
   for p in 21 22 23 80 443 2323 8080; do ss -tln | grep -q ":$p " && echo "$p ok" || echo "$p MISSING"; done; \
   curl -s -o /dev/null -w "http %{http_code}\n" http://127.0.0.1:80/'
```

Expect the slot `active`, `nftables` `active`, every honeypot port `ok`, and
`http 200`. A reboot that does not come back clean is a provisioning defect.

## Step 8 - Hand off

Give the operator the access block verbatim from `/root/sweetty-access.txt`: the
admin port, the `ssh -p PORT deploy@HOST` login, and the
`ssh -fN -L 8888:127.0.0.1:8888 deploy@HOST -p PORT` tunnel to `http://localhost:8888`.

## Invariants (do not violate)

- Never deploy `latest`; always a pinned tag verified against `checksums.txt`.
- Never widen admin SSH beyond `OPERATOR_IP`; the renderer rejects an all-internet
  wildcard, and so should you.
- Never leave a private key on the host. Never disarm the failsafe before
  confirming `deploy` login. Never skip the reboot check.
