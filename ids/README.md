# Intrusion detection

These tripwires watch for the handful of events that must never happen on a
healthy SweeTTY host. They are tuned for near-zero false positives, so an alert
is meant to be believed and acted on, not triaged away.

## Why these specific events

The honeypot's own design contract (see the product `VISION.md` and `AGENTS.md`)
guarantees three things the deception process never does:

1. It never spawns a child process. Everything an attacker "runs" is emulated
   in-process; nothing is handed to a real shell.
2. It never opens an outbound connection. Downloads are theatre, the URL is
   logged and never fetched, so the process has no reason to call `connect()`.
3. It never writes outside its own log. Files an attacker "creates" live in an
   in-memory overlay that evaporates on disconnect.

That makes the inverse a perfect alarm. If the `sweetty` user ever execs a
child, dials out, or writes to a binary, the config, or a persistence location,
the deception's safety boundary has been crossed (or the box is being tampered
with through some other path). There is no benign version of these events here.

## What is watched

| Layer | Tripwire | File |
|-------|----------|------|
| auditd | execve / connect by the `sweetty` uid; writes to slot binaries, config, identity, sudoers, cron, units, ssh keys, `ld.so.preload`; module loads | `auditd/sweetty.rules` |
| osquery | `sweetty` user running anything but its slot binary; outbound `connect` by `sweetty`; writes to protected and persistence paths | `osquery/packs/sweetty-tripwires.conf` |

auditd is the primary, kernel-level tripwire and needs no extra repo. osquery is
optional and gives you scheduled, queryable results that ship cleanly into a SIEM;
provision.sh installs it only if `osqueryd` is present.

## Defence in depth

These alarms sit behind controls that should prevent the bad event in the first
place, so a tripwire firing usually means a prevention layer was bypassed:

- systemd `ProtectSystem=strict` plus `ReadWritePaths=/opt/sweetty` makes the
  filesystem read-only to the service except its log dir.
- The nftables `meta skuid` rule denies the `sweetty` user all egress and logs
  the attempt, so tripwire 2 has a network-layer twin.
- `SystemCallFilter` and `CapabilityBoundingSet` shrink what the process can ask
  the kernel for at all.

## Tuning notes

- The only expected `execve` under the `sweetty` uid is systemd starting the
  slot binary at boot or deploy. Everything after that is an alarm.
- If you add a feature to sweetty that legitimately resolves DNS or calls out,
  these rules will fire by design. That is a signal to reconsider, not to widen
  the rule.
- Set `-e 2` in `auditd/sweetty.rules` to make the audit config immutable until
  reboot once you are happy with it.
