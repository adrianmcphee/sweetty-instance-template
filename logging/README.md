# Off-host logging

A honeypot is a box you are prepared to lose. The intelligence it collects only
counts if it has already left the host by the time anything goes wrong. Two
mechanisms work together:

1. **Append-only on disk.** provision.sh runs `chattr +a` on `sweetty.log`, so a
   process that somehow escaped the deception still cannot rewrite or truncate
   the record of itself. It can only append.
2. **Continuous off-host shipping.** The host forwards every event to a remote
   collector over the single egress port the firewall allows.

## Pick one shipper

| File | Use when |
|------|----------|
| `rsyslog/60-sweetty.conf` | rsyslog is already on the box (it is, on Ubuntu). provision.sh installs and templates this one automatically when `LOG_ENDPOINT` is set. |
| `vector.toml` | Your collector speaks Vector, or you want JSON parsed end to end with checkpointed tailing. Install Vector and run it as a service. |

Both read `/opt/sweetty/sweetty.log`, where each line is one self-contained JSON
event, and forward to `LOG_ENDPOINT` from the instance env. Use TLS off-host;
both configs show how.

## The append-only rotation caveat

`chattr +a` means the file can be appended to but not renamed, truncated, or
deleted, so the usual rotation tricks do not apply:

- `copytruncate` cannot truncate an append-only file, so it will fail.
- A rename-and-create rotation cannot rename it either.

Options, in order of preference:

- **Do not rotate locally.** Let the shipper tail the file and treat the remote
  collector as the system of record. Size the disk for the retention you want
  and ship aggressively. This is the simplest and safest for a honeypot.
- **Rotate with a brief unlock.** If you must rotate on the host, the sequence is
  `chattr -a`, rotate, recreate, `chattr +a`, and have sweetty reopen the log.
  Script it so the window where the file is mutable is as short as possible.

## Firewall coupling

The egress allowlist opens exactly the log port (`LOG_ENDPOINT`'s port) and
nothing else outbound for the host, while the `sweetty` user gets no egress at
all. Keep the shipper running as a normal system user (root for rsyslog, a
`vector` user for Vector), never as `sweetty`, or the egress-deny tripwire will
(correctly) drop and log it.
