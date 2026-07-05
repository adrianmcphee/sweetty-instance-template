# Instance Architecture

How one SweeTTY honeypot sits on a host: what is exposed, what is locked down, and how the operator reaches it. See [`README.md`](./README.md) for the operating flows.

## The honeypot host

The honeypot ports face the world. The management plane has no public footprint: the portal binds loopback, the operator reaches it by tunnelling the real SSH, and the box only ever talks outbound to ship its log.

```mermaid
flowchart TB
    BOT([Scanners and attackers]) -->|attack| HP
    OP([Operator]) -->|"SSH key auth"| SSHD

    subgraph HOST["Honeypot host (assume it will be lost)"]
        direction TB
        FW{{"nftables<br/>egress denied by default<br/>only admin SSH open to operator"}}
        HP["Honeypot ports<br/>selected by SWEETTY_PROFILE"]
        SSHD["Real sshd<br/>randomized http-like port<br/>e.g. 8088, operator-only"]
        SW["sweetty binary<br/>unprivileged user"]
        PORTAL["Portal<br/>127.0.0.1 only"]
        LOG[("sweetty.log<br/>append-only")]

        HP --> SW
        SW --> LOG
        SW --> PORTAL
        SSHD -->|"ssh -L tunnel"| PORTAL
    end

    LOG -->|"rsyslog over TLS"| COLL[("Off-host collector")]
```

The operator never opens a management port. They `ssh -L <local>:127.0.0.1:<portal_port> operator@host -p <admin_ssh_port>` and open the portal at `localhost`. The admin SSH port is randomized per instance from a pool of http-like ports so it blends in as a web service, and it is the only port the firewall opens to the operator.

## HAProxy edge (the default)

HAProxy is the default edge (`TOPOLOGY=haproxy`; set `direct` to have sweetty bind the public ports itself). It fronts only the profile-selected honeypot ports, to preserve the real attacker source IP (PROXY protocol), shed obvious floods with gentle per-source limits (turned into `FLOOD_BLOCKED` events by `sweetty-hapwatch`), and route blue/green deploys. It does not front the portal, which stays loopback and SSH-tunnel-only. Its stats console is reached through the portal over that same tunnel. It is started after sshd has moved off port 22, so its bind on :22 succeeds.

```mermaid
flowchart LR
    ATK([Attacker]) --> HAP["HAProxy<br/>public honeypot ports"]
    HAP -->|"send-proxy<br/>(real source IP)"| BK["sweetty<br/>loopback backends"]
    OP([Operator]) -->|SSH tunnel| PORTAL["Portal<br/>loopback"]
    PORTAL -->|"/dashboard/console/haproxy/"| STATS["HAProxy stats<br/>127.0.0.1 only"]
```

## Deploy and lifecycle

Provisioning hardens the host and lays out the slots; deploys are pinned, checksum-verified, and blue/green. No binary runs until an explicit tag is deployed.

```mermaid
flowchart LR
    ENV["sweetty.instance.env"] --> PROV["provision.sh<br/>users, firewall, sshd,<br/>log shipping, slots"]
    REL["GitHub release<br/>pinned tag + checksums"] --> DEP["deploy.sh<br/>slotdeploy blue/green"]
    PROV --> HOST["Hardened host"]
    DEP --> HOST
```
