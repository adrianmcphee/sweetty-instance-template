#!/usr/bin/env bash
#
# Idempotent host provisioning for a SweeTTY honeypot sensor.
#
# Run this on a fresh Ubuntu host as root (cloud-init calls it for you, or run
# it by hand after reconnecting). It is safe to run repeatedly; each step checks
# its own state first.
#
#   sudo INSTANCE_ENV=/path/to/sweetty.instance.env provision/provision.sh
#
# What it does:
#   - creates the unprivileged sweetty user and a narrow deploy user
#   - lays out /opt/sweetty and installs the config and the two slot units
#   - moves real SSH to a non-standard port and hardens sshd
#   - loads the nftables firewall and sysctl hardening
#   - installs auditd rules, the optional osquery pack, and log shipping
#   - makes sweetty.log append-only
#
# It does NOT deploy a binary or start the honeypot. Run a deploy for that
# (deploy/deploy.sh), so the running version is always an explicit, pinned tag.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	echo "provision.sh must run as root" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTANCE_ENV="${INSTANCE_ENV:-${REPO_ROOT}/sweetty.instance.env}"
if [[ ! -f "${INSTANCE_ENV}" ]]; then
	echo "instance config not found: ${INSTANCE_ENV}" >&2
	echo "copy sweetty.instance.env.example to sweetty.instance.env and fill it in" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "${INSTANCE_ENV}"

SWEETTY_USER="${SWEETTY_USER:-sweetty}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sweetty}"
# Management SSH port. Randomized per instance from a pool of http-like ports so
# it blends in as just another web service rather than screaming "admin
# backdoor", and so there is no fixed admin-port tell across the fleet. When the
# env leaves it empty it is generated once and recorded back into the instance
# env, so every later provision, the firewall renderer, and deploy all agree on
# the same port. The portal is NOT exposed: it binds loopback and is reached only
# by forwarding this SSH port to it.
if [[ -z "${ADMIN_SSH_PORT:-}" ]]; then
	# Plausible web/app ports, widened for real per-instance variation so the fleet
	# has no shared admin-port tell, yet each still looks like an ordinary service.
	# Curated to avoid every port already in use on the box: the honeypot listeners
	# (21 22 23 80 443 2323 8080), the loopback HAProxy backends (100xx 12323 18080
	# 19000), and the portal (8888, which the tunnel forwards to).
	admin_port_pool=(8000 8001 8008 8081 8082 8083 8085 8090 8091 8181 8200 8443 8800 8880 9000 9001 9080 9090 9100 9443)
	ADMIN_SSH_PORT="${admin_port_pool[RANDOM % ${#admin_port_pool[@]}]}"
	printf '\n# Randomized by provision.sh on first run.\nADMIN_SSH_PORT="%s"\n' "${ADMIN_SSH_PORT}" >> "${INSTANCE_ENV}"
	echo "generated a random management SSH port: ${ADMIN_SSH_PORT} (recorded in ${INSTANCE_ENV})"
fi

log() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
log "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# Apply pending updates now, while egress is still open. Once the firewall loads,
# the host can reach only DNS, the release host on 443, and the log collector, so
# apt mirror traffic (often http on 80) would be blocked and patching would fail.
apt-get upgrade -y
apt-get install -y \
	nftables auditd audispd-plugins \
	libcap2-bin ca-certificates curl jq \
	rsyslog
# HAProxy edge (haproxy topology, the default): a transparent TCP front that
# preserves the real attacker IP via the PROXY protocol and sheds obvious floods.
if [[ "${TOPOLOGY:-haproxy}" == "haproxy" ]]; then
	apt-get install -y haproxy
fi
# osquery lives in its own apt repo; install it best-effort so provisioning does
# not fail on a host where the operator chose not to add that repo.
if ! command -v osqueryd >/dev/null 2>&1; then
	if apt-get install -y osquery 2>/dev/null; then
		echo "osquery installed"
	else
		echo "osquery not available from configured repos; the auditd tripwires still apply"
	fi
fi

# ---------------------------------------------------------------------------
log "Users"
if ! id "${SWEETTY_USER}" >/dev/null 2>&1; then
	useradd --system --shell /usr/sbin/nologin --home-dir "${INSTALL_DIR}" --no-create-home "${SWEETTY_USER}"
	echo "created ${SWEETTY_USER}"
fi
if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
	useradd --system --create-home --shell /bin/bash "${DEPLOY_USER}"
	echo "created ${DEPLOY_USER}"
fi
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

# ---------------------------------------------------------------------------
log "Layout: ${INSTALL_DIR}"
# 0751, not 0750: the deploy user is not in the sweetty group, but slotdeploy
# (running as deploy) must traverse INSTALL_DIR to reach its state dir and the
# active-slot marker below. o+x grants traverse only; deploy still cannot list the
# dir or read the log (sweetty.log is 0640 sweetty:sweetty).
install -d -m 0751 -o root -g "${SWEETTY_USER}" "${INSTALL_DIR}"
install -d -m 0750 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${INSTALL_DIR}/deploy"
install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${INSTALL_DIR}/deploy/slots"

# The config is operator-owned; never clobber an existing one, only seed it the
# first time.
if [[ ! -f "${INSTALL_DIR}/config.json" ]]; then
	# TOPOLOGY selects the seed: the direct config binds the public ports, the
	# haproxy config binds loopback backend ports for the HAProxy edge to front.
	CONFIG_SRC="${SCRIPT_DIR}/config.json"
	if [[ "${TOPOLOGY:-haproxy}" == "haproxy" ]]; then
		CONFIG_SRC="${REPO_ROOT}/haproxy/config.haproxy.json"
	fi
	install -m 0640 -o root -g "${SWEETTY_USER}" "${CONFIG_SRC}" "${INSTALL_DIR}/config.json"
	echo "seeded config.json from ${CONFIG_SRC##*/} (portal binds loopback, no login; reach it over the SSH tunnel)"
fi

# Active-slot marker, owned by the deploy user so slotdeploy can rewrite it
# without sudo.
if [[ ! -f "${INSTALL_DIR}/.active-slot" ]]; then
	echo "blue" > "${INSTALL_DIR}/.active-slot"
	chown "${DEPLOY_USER}:${DEPLOY_USER}" "${INSTALL_DIR}/.active-slot"
fi

# Pre-create the log so we can set ownership and the append-only flag even
# before the first run.
if [[ ! -f "${INSTALL_DIR}/sweetty.log" ]]; then
	install -m 0640 -o "${SWEETTY_USER}" -g "${SWEETTY_USER}" /dev/null "${INSTALL_DIR}/sweetty.log"
fi

# Writable state dir for the honeypot's generated identity. INSTALL_DIR is
# operator-owned and read-only to the sweetty user, but the persona is written by
# the honeypot (atomically, via a temp file) on first run, so it needs a directory
# the honeypot owns. config.json points persona_file at state/persona.json. Mode
# 0700: only the honeypot reads or writes it. This keeps the slot binaries and the
# operator config unwritable by the deception process while still letting it
# persist its identity.
install -d -m 0700 -o "${SWEETTY_USER}" -g "${SWEETTY_USER}" "${INSTALL_DIR}/state"

# Session recordings (asciinema casts, one per connection) land here when
# record_dir is set in config.json. The honeypot user owns it and nothing else
# can read it. A systemd-tmpfiles rule ages casts out so they cannot fill the
# disk on a busy sensor; tune RECORD_RETENTION_DAYS in the instance env.
install -d -m 0700 -o "${SWEETTY_USER}" -g "${SWEETTY_USER}" "${INSTALL_DIR}/recordings"
printf 'd %s/recordings 0700 %s %s %sd\n' \
	"${INSTALL_DIR}" "${SWEETTY_USER}" "${SWEETTY_USER}" "${RECORD_RETENTION_DAYS:-14}" \
	> /etc/tmpfiles.d/sweetty-recordings.conf
systemd-tmpfiles --create /etc/tmpfiles.d/sweetty-recordings.conf 2>/dev/null \
	&& echo "session recordings retained ${RECORD_RETENTION_DAYS:-14}d in ${INSTALL_DIR}/recordings" \
	|| echo "tmpfiles rule for recordings installed (applied on next boot)"

# ---------------------------------------------------------------------------
log "Geo databases"
# The portal tags each source with a country and an ISP/ASN from offline
# databases (the honeypot host has no egress to query a service). Fetch them now,
# while egress is still open; config.json points geoip_file/asn_file at these
# paths. A fetch failure is non-fatal: the portal just shows address scope until
# the databases exist. Override the URLs via GEO_COUNTRY_URL / GEO_ASN_URL.
#
# sapics/ip-location-db publishes the CSVs to npm and serves them on jsDelivr's
# CDN; the old raw.githubusercontent.com/.../main paths 404 (the repo restructured),
# so pull from the CDN. Same filenames and format the geo parser already expects.
install -d -m 0750 -o root -g "${SWEETTY_USER}" "${INSTALL_DIR}/geo"
GEO_COUNTRY_URL="${GEO_COUNTRY_URL:-https://cdn.jsdelivr.net/npm/@ip-location-db/geo-whois-asn-country/geo-whois-asn-country-ipv4.csv}"
GEO_ASN_URL="${GEO_ASN_URL:-https://cdn.jsdelivr.net/npm/@ip-location-db/asn/asn-ipv4.csv}"
fetch_geo() {
	local url="$1" dest="$2" name="$3" tmp
	tmp="$(mktemp)"
	if curl -fsSL --retry 3 -o "${tmp}" "${url}" && [[ -s "${tmp}" ]]; then
		install -m 0640 -o root -g "${SWEETTY_USER}" "${tmp}" "${dest}"
		echo "fetched ${name} database ($(wc -l <"${dest}") rows) -> ${dest}"
	else
		echo "WARNING: could not fetch ${name} database from ${url}; portal shows scope only until it exists" >&2
	fi
	rm -f "${tmp}"
}
fetch_geo "${GEO_COUNTRY_URL}" "${INSTALL_DIR}/geo/country-ipv4.csv" "country"
fetch_geo "${GEO_ASN_URL}" "${INSTALL_DIR}/geo/asn-ipv4.csv" "ASN"

# ---------------------------------------------------------------------------
log "Systemd slot units"
install -m 0644 "${SCRIPT_DIR}/systemd/sweetty-blue.service" /etc/systemd/system/sweetty-blue.service
install -m 0644 "${SCRIPT_DIR}/systemd/sweetty-green.service" /etc/systemd/system/sweetty-green.service
install -m 0644 "${SCRIPT_DIR}/systemd/sweetty-hapwatch.service" /etc/systemd/system/sweetty-hapwatch.service
systemctl daemon-reload

# ---------------------------------------------------------------------------
log "slotdeploy"
# The blue/green deploy runtime that deploy.sh hands off to. Fetch a pinned,
# checksum-verified static binary so the honeypot host needs no Go toolchain (one
# fewer thing on a box we treat as already hostile). Runs while egress is still
# open, before the firewall step below.
SLOTDEPLOY_REPO="${SLOTDEPLOY_REPO:-adrianmcphee/slotdeploy}"
SLOTDEPLOY_VERSION="${SLOTDEPLOY_VERSION:-v0.1.0}"
if ! command -v slotdeploy >/dev/null 2>&1; then
	case "$(uname -m)" in
	x86_64 | amd64) sd_arch="amd64" ;;
	aarch64 | arm64) sd_arch="arm64" ;;
	*) echo "unsupported arch for slotdeploy: $(uname -m)" >&2; exit 1 ;;
	esac
	sd_asset="slotdeploy_${SLOTDEPLOY_VERSION#v}_linux_${sd_arch}"
	sd_base="https://github.com/${SLOTDEPLOY_REPO}/releases/download/${SLOTDEPLOY_VERSION}"
	sd_tmp="$(mktemp -d)"
	curl -fsSL "${sd_base}/${sd_asset}" -o "${sd_tmp}/slotdeploy"
	curl -fsSL "${sd_base}/checksums.txt" -o "${sd_tmp}/checksums.txt"
	# Match the checksum line by exact filename field, not a regex: the dots in the
	# pinned version must not act as wildcards (0.1.0 could otherwise match 0X1X0).
	sd_want="$(awk -v f="${sd_asset}" '$2 == f || $2 == "./" f {print $1}' "${sd_tmp}/checksums.txt")"
	sd_got="$(sha256sum "${sd_tmp}/slotdeploy" | awk '{print $1}')"
	if [[ -z "${sd_want}" || "${sd_want}" != "${sd_got}" ]]; then
		echo "slotdeploy checksum mismatch (want ${sd_want:-none}, got ${sd_got}); refusing" >&2
		exit 1
	fi
	install -m 0755 -o root -g root "${sd_tmp}/slotdeploy" /usr/local/bin/slotdeploy
	rm -rf "${sd_tmp}"
	echo "installed slotdeploy ${SLOTDEPLOY_VERSION} to /usr/local/bin/slotdeploy"
else
	echo "slotdeploy already present: $(command -v slotdeploy)"
fi

# ---------------------------------------------------------------------------
log "HAProxy edge"
if [[ "${TOPOLOGY:-haproxy}" == "haproxy" ]]; then
	install -d -m 0755 /etc/haproxy
	install -m 0644 "${REPO_ROOT}/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
	# The runtime admin socket lives in /run/haproxy; the package ships a tmpfiles
	# rule for it, but create it now so a fresh provision does not race the unit.
	install -d -m 0750 -o haproxy -g haproxy /run/haproxy 2>/dev/null || true
	# Fail closed: never front the honeypot with a ruleset HAProxy itself rejects.
	if ! haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
		echo "ERROR: haproxy.cfg failed its own syntax check; refusing to start HAProxy" >&2
		haproxy -c -f /etc/haproxy/haproxy.cfg || true
		exit 1
	fi
	# Enable both now, but START them at the end of provisioning, after sshd has
	# moved off port 22 (see "Start the edge"). HAProxy must bind :22; if it starts
	# while the real sshd still holds 22, that bind fails and HAProxy, being
	# all-or-nothing, binds NONE of its frontends while still reporting "Ready", so
	# it silently fronts nothing and the slot health-check (which probes through it)
	# times out. hapwatch reads HAProxy's socket, so it waits for the same moment.
	systemctl enable haproxy sweetty-hapwatch.service
	echo "HAProxy edge configured (PROXY protocol, gentle flood limits); starts after sshd leaves :22"
else
	# Direct topology: ensure no edge from a prior haproxy provisioning still fronts
	# the ports (idempotent re-provision into a different topology).
	systemctl disable --now haproxy sweetty-hapwatch.service 2>/dev/null || true
	echo "direct topology: sweetty binds the public ports itself; no HAProxy"
fi

# ---------------------------------------------------------------------------
log "Deploy sudoers"
SUDOERS_RENDERED="$(mktemp)"
sed "s/__DEPLOY_USER__/${DEPLOY_USER}/g" "${SCRIPT_DIR}/sudoers/sweetty-deploy.template" > "${SUDOERS_RENDERED}"
if visudo -c -f "${SUDOERS_RENDERED}" >/dev/null; then
	install -m 0440 -o root -g root "${SUDOERS_RENDERED}" /etc/sudoers.d/sweetty-deploy
	echo "installed /etc/sudoers.d/sweetty-deploy"
else
	echo "rendered sudoers failed validation; not installing" >&2
	rm -f "${SUDOERS_RENDERED}"
	exit 1
fi
rm -f "${SUDOERS_RENDERED}"

# ---------------------------------------------------------------------------
log "SSH on port ${ADMIN_SSH_PORT}"
# Real SSH must leave port 22 so the honeypot can bind it. The firewall already
# restricts the admin port to the operator address.
install -d -m 0755 /etc/ssh/sshd_config.d
# Named 00- so it sorts BEFORE distro drop-ins such as 50-cloud-init.conf. sshd
# uses the FIRST value seen for each keyword, and cloud-init images commonly ship
# PasswordAuthentication yes, which would otherwise win and leave password auth on.
# Remove any 99-named copy from an earlier provision so only this one is read.
rm -f /etc/ssh/sshd_config.d/99-sweetty.conf
cat > /etc/ssh/sshd_config.d/00-sweetty.conf <<EOF
# Managed by SweeTTY provision.sh. Real SSH lives here so port 22 is free for
# the honeypot. Reachable only from the operator address (see nftables). Key auth
# only: this overrides any distro default that would enable password auth.
Port ${ADMIN_SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
EOF
echo "sshd will listen on ${ADMIN_SSH_PORT}. If you are connected over port 22,"
echo "reconnect on ${ADMIN_SSH_PORT} after this script restarts sshd."

# ---------------------------------------------------------------------------
log "Firewall (nftables)"
# nftables owns the whole ruleset here, so stand down ufw if it is active.
if command -v ufw >/dev/null 2>&1; then
	ufw --force disable || true
fi
install -d -m 0755 /etc/nftables.d
OUTPUT=/etc/nftables.d/sweetty.nft INSTANCE_ENV="${INSTANCE_ENV}" "${SCRIPT_DIR}/render-nftables.sh"
# Point the system nftables unit at our ruleset.
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/sweetty.nft"
EOF
nft -c -f /etc/nftables.d/sweetty.nft
# enable --now starts the unit, which runs `nft -f /etc/nftables.conf`: the ruleset
# loads now AND `systemctl is-active nftables` reads active, instead of the
# confusing "inactive" that hand-loading the ruleset leaves behind.
systemctl enable --now nftables
echo "nftables active"

# ---------------------------------------------------------------------------
log "Sysctl hardening"
install -m 0644 "${SCRIPT_DIR}/sysctl/99-sweetty-hardening.conf" /etc/sysctl.d/99-sweetty-hardening.conf
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
log "Intrusion detection (auditd)"
if [[ -f "${REPO_ROOT}/ids/auditd/sweetty.rules" ]]; then
	SWEETTY_UID="$(id -u "${SWEETTY_USER}")"
	sed "s/__SWEETTY_UID__/${SWEETTY_UID}/g" "${REPO_ROOT}/ids/auditd/sweetty.rules" \
		> /etc/audit/rules.d/sweetty.rules
	augenrules --load || systemctl restart auditd || true
	echo "auditd rules loaded"
fi
if [[ -f "${REPO_ROOT}/ids/osquery/osquery.conf" ]] && command -v osqueryd >/dev/null 2>&1; then
	install -d -m 0755 /etc/osquery /etc/osquery/packs
	install -m 0644 "${REPO_ROOT}/ids/osquery/osquery.conf" /etc/osquery/osquery.conf
	install -m 0644 "${REPO_ROOT}/ids/osquery/packs/sweetty-tripwires.conf" /etc/osquery/packs/sweetty-tripwires.conf
	systemctl enable --now osqueryd || true
	echo "osquery pack installed"
fi

# ---------------------------------------------------------------------------
log "Off-host log shipping"
if [[ -n "${LOG_ENDPOINT:-}" && -f "${REPO_ROOT}/logging/rsyslog/60-sweetty.conf" ]]; then
	LOG_HOST="${LOG_ENDPOINT%%:*}"
	LOG_PORT="${LOG_ENDPOINT##*:}"
	TLS_GLOBAL=""
	TLS_PARAMS=""
	if [[ "${LOG_TRANSPORT:-tls}" == "tls" ]]; then
		# Encrypt the forward. Refuse to ship in plaintext if gnutls is unavailable,
		# so "tls" never silently degrades to cleartext credentials on the wire.
		if ! dpkg -s rsyslog-gnutls >/dev/null 2>&1; then
			apt-get install -y rsyslog-gnutls \
				|| { echo "ERROR: rsyslog-gnutls unavailable; refusing to ship logs in plaintext" >&2; exit 1; }
		fi
		LOG_CA_FILE="${LOG_CA:-/etc/ssl/certs/ca-certificates.crt}"
		# Pin the collector's certificate name. x509/name on its own only proves the
		# peer holds a cert from a trusted CA, not WHICH host it is, so any host with
		# any CA-signed cert could receive the exfiltrated log. Pin the permitted peer
		# to the collector's cert name (the endpoint host by default; override with
		# LOG_PEER_NAME when the cert subject/SAN differs from the name you connect
		# to). Fail closed: refuse to ship if there is no name to authenticate
		# against, rather than trust any CA-signed peer.
		LOG_PEER="${LOG_PEER_NAME:-${LOG_HOST}}"
		if [[ -z "${LOG_PEER}" ]]; then
			echo "ERROR: TLS log forwarding needs a peer name to authenticate the collector; set LOG_PEER_NAME (or a host in LOG_ENDPOINT)" >&2
			exit 1
		fi
		TLS_GLOBAL="global(defaultNetstreamDriver=\"gtls\" defaultNetstreamDriverCAFile=\"${LOG_CA_FILE}\")"
		TLS_PARAMS="\n         StreamDriver=\"gtls\" StreamDriverMode=\"1\" StreamDriverAuthMode=\"x509/name\" StreamDriverPermittedPeers=\"${LOG_PEER}\""
	fi
	sed -e "s|__LOG_HOST__|${LOG_HOST}|g" \
		-e "s|__LOG_PORT__|${LOG_PORT}|g" \
		-e "s|__LOG_TLS_GLOBAL__|${TLS_GLOBAL}|g" \
		-e "s|__LOG_TLS_PARAMS__|${TLS_PARAMS}|g" \
		"${REPO_ROOT}/logging/rsyslog/60-sweetty.conf" > /etc/rsyslog.d/60-sweetty.conf
	systemctl restart rsyslog || true
	echo "rsyslog forwards sweetty.log to ${LOG_ENDPOINT} over ${LOG_TRANSPORT:-tls}"
else
	echo "no LOG_ENDPOINT set (or rsyslog template missing); skipping off-host shipping"
fi

# ---------------------------------------------------------------------------
log "Append-only log"
# A shell that somehow escaped the deception still cannot rewrite history.
chattr +a "${INSTALL_DIR}/sweetty.log" 2>/dev/null \
	&& echo "sweetty.log is append-only (chattr +a)" \
	|| echo "could not set +a (unsupported filesystem?); ship logs off-host regardless"

# ---------------------------------------------------------------------------
log "Restart sshd"
systemctl restart ssh || systemctl restart sshd || true

# ---------------------------------------------------------------------------
# Start the edge now that sshd has vacated port 22, so HAProxy binds :22 and the
# other public ports cleanly. Deferred to here (rather than the HAProxy step
# above) precisely so its all-or-nothing bind cannot fail against the sshd that
# still held 22 at that point. restart (not start) keeps re-provisioning idempotent.
if [[ "${TOPOLOGY:-haproxy}" == "haproxy" ]]; then
	log "Start the edge"
	systemctl restart haproxy
	systemctl restart sweetty-hapwatch.service || true
	echo "HAProxy edge started: public ports bound"
fi

# ---------------------------------------------------------------------------
# Admin access summary. Real SSH is on a per-instance randomized port reachable
# only from the operator address, so the one thing an operator must never lose is
# "which port, and the exact command to tunnel the portal". Resolve the real
# values now (host IP, port, user) into copy-paste commands, write them where the
# provider serial console can read them as root (an unattended install never sees
# this script's stdout), and print them last so an interactive run ends on them.
host_addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -z "${host_addr}" ]] && host_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${host_addr}" ]] && host_addr="<this-host-public-ip>"
portal_port="${PORTAL_PORT:-8888}"
access_file="/root/sweetty-access.txt"
cat > "${access_file}" <<EOF
SweeTTY admin access for this host
==================================
Real SSH is NOT on port 22 (port 22 is the honeypot). It listens on a
per-instance randomized port, reachable only from your operator address
(${OPERATOR_IP:-<operator-ip>}). Root login and password auth are disabled; the
only login is the ${DEPLOY_USER} user with its key.

  Admin port : ${ADMIN_SSH_PORT}

  Log in:
    ssh -p ${ADMIN_SSH_PORT} ${DEPLOY_USER}@${host_addr}

  Open the management console (forward the loopback portal, then browse to it):
    ssh -fN -L ${portal_port}:127.0.0.1:${portal_port} ${DEPLOY_USER}@${host_addr} -p ${ADMIN_SSH_PORT}
    open http://localhost:${portal_port}
    (close the tunnel later: pkill -f '${portal_port}:127.0.0.1:${portal_port}')

If ${host_addr} is a private/NAT address, substitute this host's public IP.
EOF
chmod 600 "${access_file}"

printf '\n=== Provisioning complete ===\n\n'
cat "${access_file}"
printf '\nSaved to %s (readable from the provider serial console).\n' "${access_file}"
# A by-hand provision (no cloud-init, no bootstrap.sh) still needs the deploy key
# and a first release; cloud-init and bootstrap.sh both do these for you.
cat <<EOF

If you provisioned by hand, finish with:
  1. Add the deploy public key:
       install -d -m 700 -o ${DEPLOY_USER} -g ${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh
       echo '<deploy pubkey>' >> /home/${DEPLOY_USER}/.ssh/authorized_keys
       chown ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh/authorized_keys
       chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys
  2. Deploy a pinned release (never 'latest'):
       deploy/deploy.sh ${RELEASE_TAG:-vX.Y.Z}
EOF
