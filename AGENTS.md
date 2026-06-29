# Agent Instructions: sweetty-instance-template

Read [`README.md`](./README.md) and [`ARCHITECTURE.md`](./ARCHITECTURE.md) first.
This repo turns a fresh Ubuntu host into a hardened
[SweeTTY](https://github.com/adrianmcphee/sweetty) honeypot running a pinned
release. The product repo builds the binary; this repo provisions and operates it.
Everything below is the working contract.

---

## Hard rules (do not violate)

1. **No AI attribution in git commits.** No `Co-Authored-By`, no "Generated with",
   no emoji. Commits represent human authorship. Enforced by the commit-msg hook
   (`make hooks` installs it).
2. **No em dashes**, anywhere, in code, configs, or docs. Enforced by `make check`.
3. **Never commit an instance's secrets.** `sweetty.instance.env` (operator address,
   log endpoint) is gitignored; the committed `*.example` carries only placeholders.
4. **Never deploy `latest`.** Always an explicit release tag, verified against
   `checksums.txt` before the slot swap.
5. **Never widen admin SSH beyond `OPERATOR_IP`.** The nftables renderer rejects an
   all-internet wildcard; do not work around it.

---

## What this is

A provisioning and deploy layer. `provision.sh` hardens a fresh host (an
unprivileged honeypot user, an nftables deny-by-default firewall, a randomized
operator-only admin SSH, the HAProxy edge, log shipping, systemd slot units).
`deploy.sh` brings up a pinned release with slotdeploy's blue/green swap.
`bootstrap.sh` runs both end to end over root SSH. The threat model is
assume-escape: treat the box as something you will lose.

---

## Bringing up a box over root SSH

A deterministic procedure. The one value that must be right is `OPERATOR_IP`: admin
SSH is firewalled to it alone, so a wrong value locks management out. There is no
in-band failsafe by design (a box-reverting timer is fragile and the box is
disposable); recover a lockout by rebuilding, or via the provider serial console.
The safe move is to not get it wrong: an agent running from the operator's own
machine reads the address back from the live session rather than guessing.

### 1. Preconditions
- Root SSH to a fresh Ubuntu 24.04/26.04, x86_64 host that exists only to be attacked.
- A deploy SSH keypair. You install the public key; never put a private key on the box.
- A pinned release tag from https://github.com/adrianmcphee/sweetty/releases.

### 2. Determine OPERATOR_IP (do not guess)
Running from the operator's machine/network, the host already sees that address as
your session source. Read it back and confirm with the operator:
```bash
ssh root@HOST 'echo "${SSH_CONNECTION%% *}"'   # first field = operator public IP
```
If you are not on the operator's network, you must be told the IP explicitly. Never
substitute your own egress IP.

### 3. Stage the repo, env, and key
Render `sweetty.instance.env` from the example: set `OPERATOR_IP` and `RELEASE_TAG`,
leave `ADMIN_SSH_PORT=""` to randomize the real-SSH port, keep `TOPOLOGY="haproxy"`.
Then:
```bash
rsync -a --exclude='.git' ./ root@HOST:/root/sweetty-instance-template/
scp sweetty.instance.env root@HOST:/root/sweetty-instance-template/sweetty.instance.env
scp deploy.pub          root@HOST:/root/deploy.pub
ssh root@HOST 'grep -E "^(OPERATOR_IP|RELEASE_TAG|ADMIN_SSH_PORT|TOPOLOGY)=" /root/sweetty-instance-template/sweetty.instance.env'
```

### 4. Bootstrap (provision + deploy key + first release + verify)
One root command; it refuses to succeed unless the honeypot is actually serving,
and the first deploy runs as the deploy user so nothing root-owned is left behind:
```bash
ssh root@HOST 'cd /root/sweetty-instance-template && \
  INSTANCE_ENV=$PWD/sweetty.instance.env DEPLOY_PUBKEY=/root/deploy.pub ./bootstrap.sh'
```
It ends by printing the randomized admin port and the exact login + tunnel commands
(also saved to `/root/sweetty-access.txt`). If it prints `VERIFY FAILED`, stop and
read the log; do not hand off.

### 5. Confirm operator access
Provisioning moved sshd to the randomized port and disabled root login. Read the
port back and prove the operator's real path works:
```bash
PORT=$(ssh root@HOST 'sed -n "s/^ADMIN_SSH_PORT=\"\\(.*\\)\"/\\1/p" /root/sweetty-instance-template/sweetty.instance.env')
ssh -p "$PORT" deploy@HOST 'echo ok; systemctl is-active "sweetty-$(cat /opt/sweetty/.active-slot)".service haproxy'
```
If you cannot log in as deploy, the operator IP or key is wrong: rebuild (or recover
via the provider serial console), fix the value, and redo from step 3.

### 6. Reboot and verify durability (required)
A honeypot must survive an unattended reboot. The randomized SSH port also makes a
clean boot the moment HAProxy binds the public ports (port 22 is free from boot):
```bash
ssh -p "$PORT" deploy@HOST 'sudo systemctl reboot'; sleep 75
ssh -p "$PORT" deploy@HOST \
  'systemctl is-active "sweetty-$(cat /opt/sweetty/.active-slot)".service nftables haproxy; \
   for p in 21 22 23 80 443 2323 8080; do ss -tln | grep -q ":$p " && echo "$p ok" || echo "$p MISSING"; done; \
   curl -s -o /dev/null -w "http %{http_code}\n" http://127.0.0.1:80/'
```
Expect the slot, `nftables`, and `haproxy` all active; every honeypot port bound
(through HAProxy); and `http 200`. A reboot that does not come back clean is a
provisioning defect, not a one-off.

### 7. Hand off
Give the operator the block from `/root/sweetty-access.txt`: the admin port, the
`ssh -p PORT deploy@HOST` login, and the
`ssh -fN -L 8888:127.0.0.1:8888 deploy@HOST -p PORT` tunnel to `http://localhost:8888`.

---

## Verification (before any commit)

```bash
make check        # em-dash scan, shellcheck, nftables + haproxy config validation
```

CI runs the same. If you cannot run a check, say so and say what you did run.

---

## Commit discipline

- Atomic commits, imperative scoped messages (e.g. `fix(provision): start HAProxy
  after sshd leaves :22`). No AI attribution (hard rule).
- Push as you go; `main` tracks `origin`.
- Bump the pinned `RELEASE_TAG` in the examples on purpose, never to `latest`.
