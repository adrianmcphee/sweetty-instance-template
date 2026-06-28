# Optional HAProxy edge

This layer is **optional**. The default topology has sweetty bind the public
honeypot ports directly; that is simpler and is what provision.sh sets up. Reach
for HAProxy only when you specifically want one of these:

- **Real-source-IP preservation through a proxy.** If you put anything in front
  of the honeypot, sweetty must still log the real attacker IP, not the proxy's.
- **True zero-downtime blue/green.** With the edge in place, the two slots bind
  distinct loopback ports and HAProxy routes to whichever is healthy, so a deploy
  never drops a connection (the default direct topology accepts a sub-second
  cutover instead).

HAProxy does NOT front the management portal. The portal binds loopback in every
topology and is reached over the management SSH tunnel, so there is nothing to
terminate or authenticate at the edge for it.

## The two non-negotiables

### 1. PROXY protocol to the backend

Every honeypot backend uses `send-proxy`. The PROXY protocol header tells sweetty
the real client address, so the captured log keeps recording who actually
connected rather than `127.0.0.1`. The whole value of the honeypot is the source
intelligence; losing it to a proxy hop would quietly gut the product.

This has a hard requirement on the other side: **sweetty must have
`"proxy_protocol": true`** in its config and be bound to the loopback backend
ports (see `config.haproxy.json`). If HAProxy sends the header and sweetty is not
parsing it, sweetty will treat the header bytes as the attacker's first input and
every session will be malformed, and the logged source will be HAProxy's loopback
address instead of the attacker. The two settings are a matched pair: `send-proxy`
here and `proxy_protocol` there.

### 2. Gentle rate limiting only

The stick-table thresholds in `haproxy.cfg` are high on purpose. They exist to
shed only an obvious volumetric flood that would otherwise drown the honeypot or
fill the disk, for example a single source opening hundreds of connections a
second. They are not there to throttle scanning or brute forcing.

This is the opposite of how you would tune a proxy in front of a real service.
A honeypot's job is to **let attackers in**. Aggressive upstream rate limiting
discards the exact thing the box exists to collect: the credential lists, the
command sequences, the payload URLs. A scanner that gets rate-limited at the edge
just leaves, and takes its intel with it. So keep the limits loose, and if you
ever feel the urge to tighten them to "protect" the honeypot, that urge belongs
somewhere else (see below).

## Where volumetric protection actually belongs

Edge volumetric and DDoS protection should live below the application, not in
front of it as request throttling:

- **nftables / cloud DDoS.** Connection floods, SYN floods, and amplification are
  a network-layer problem. The host's nftables ruleset (SYN cookies, ICMP rate
  limits) and your provider's network DDoS protection absorb that without
  touching the intel the honeypot collects.
- **HAProxy** is here for source-IP preservation and slot routing. Its
  stick-table is a flood circuit-breaker, not an access policy.

## This topology

This is the default (`TOPOLOGY="haproxy"`), and `provision.sh` sets it up for you:
it installs HAProxy, validates and installs `haproxy.cfg`, starts the edge, and
enables the `sweetty-hapwatch` unit that logs `FLOOD_BLOCKED` events. The steps it
performs, for reference:

1. Point sweetty at `config.haproxy.json` (loopback backend ports, loopback
   portal on 8888); it already sets `"proxy_protocol": true`. The portal binds
   loopback and is reached over the SSH tunnel, the same as the direct topology.
2. Install `haproxy.cfg`, validate it with `haproxy -c -f haproxy.cfg`, and start
   HAProxy.
3. The nftables ruleset is unchanged: the public ports stay open to the world and
   only the management SSH port is restricted to the operator. HAProxy is now the
   listener on the public honeypot ports; sweetty listens only on loopback.

## The stats console, through the portal

`haproxy.cfg` includes a `listen stats` block bound to `127.0.0.1:19000`. It is
never exposed publicly and carries no password of its own. Instead, the sweetty
portal reverse-proxies it at `/dashboard/console/haproxy/`, so an operator opens
it from the dashboard over the same SSH tunnel that reaches the portal. There is
no separate credential and no second public port: SSH key auth is the one gate.

This is wired by `admin_consoles` in `config.haproxy.json`:

```json
"admin_consoles": [
  { "name": "haproxy", "label": "HAProxy", "target": "http://127.0.0.1:19000/" }
]
```

Two settings are a matched pair, the same way `send-proxy` and PROXY parsing are:

- HAProxy's `stats uri` is set to the **portal mount path** (`/dashboard/console/haproxy`),
  not `/`. The stats page emits absolute links rooted at its uri, so matching it
  to the external mount keeps sorting, refresh, and the admin actions working
  through the proxy.
- The portal console therefore forwards the **full path** (the default). Do not
  set `strip_prefix` for this console, or the upstream uri will not match.

Admin actions (enable or disable a backend from the console) are permitted because
the only client that can reach `127.0.0.1:19000` is the local portal proxy, and the
only way to reach the portal is through the operator's SSH tunnel. Nothing off-host
can reach the bind, so the SSH tunnel is the single gate.

If you run the default direct topology (no HAProxy), there is no stats console to
proxy; drop the `admin_consoles` entry from the config.
