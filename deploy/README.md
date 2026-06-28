# Deploy

Deploys are pinned, verified, and blue/green. A deploy never tracks `latest`; it
installs one explicit release tag, checks it against the published checksums
before touching the running service, and swaps it into the inactive slot with
[slotdeploy](https://github.com/adrianmcphee/slotdeploy).

## The flow

```
deploy/deploy.sh v0.3.0
```

1. **Pin.** The tag is required. `latest` is rejected outright.
2. **Pull.** `sweetty_<ver>_linux_<arch>.tar.gz` and `checksums.txt` are fetched
   from the product repo's GitHub Releases for that tag (via `gh` when present,
   so private repos and auth just work, otherwise via `curl`).
3. **Verify.** The artifact is checked against `checksums.txt` with
   `sha256sum -c`. Nothing is installed until the checksum matches.
4. **Stage and install.** The verified binary is installed into the inactive
   slot (`/opt/sweetty/sweetty-blue` or `-green`) and the low-port capability is
   re-granted.
5. **Swap.** slotdeploy starts the new slot, health-checks it on the HTTP
   honeypot port, stops the old slot, and flips `/opt/sweetty/.active-slot`.

## Why slotdeploy, and the cutover trade

slotdeploy gives a small, auditable blue/green model: two named slots, an active
marker, a health gate, and a rollback that does not rebuild anything. We use its
`commands` runtime against the two systemd slot units.

The honeypot binds fixed low ports and a port can be held by only one process,
so in the default direct topology the two slots cannot run simultaneously. The
deploy stops the old slot and starts the new one, a sub-second gap. For a honeypot
that is the right trade: missing a handful of connections during a deploy is
fine; running two attack surfaces at once, or exposing a half-bound instance, is
not. If you need genuinely zero-downtime deploys, run the HAProxy topology, where
the slots bind distinct loopback ports and the edge routes to the healthy one
(see `../haproxy/README.md`).

## Rollback

```
slotdeploy rollback --config deploy/slotdeploy.yaml
```

The previous slot's binary is still on disk, so rollback just starts it,
health-checks it, stops the failed slot, and writes the marker back. No fetch, no
rebuild.

## Status

```
slotdeploy status --config deploy/slotdeploy.yaml
```

Prints the active slot and the release recorded for it.

## CI

`.github/workflows/deploy.yml` runs this on demand. It builds slotdeploy from a
pinned ref, ships it to the host, and runs `deploy.sh <tag>` over SSH as the
deploy user. The tag is a required workflow input, so there is no implicit
`latest` path in automation either.
