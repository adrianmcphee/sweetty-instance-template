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
	# http-like ports that do not collide with the honeypot listeners (80/8080).
	admin_port_pool=(8000 8008 8088 8090 8181 8800 8888 9000 9080 9090)
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
	if [[ "${TOPOLOGY:-direct}" == "haproxy" ]]; then
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

# Pre-create persona.json owned by the honeypot user. INSTALL_DIR itself is not
# writable by the sweetty user, so without an owned file to write into, the first
# run cannot persist its generated identity and the service exits non-zero. An
# empty owned file is enough: persona load is generate-on-first-run and
# regenerate-if-empty, so the honeypot populates it in place on first start.
if [[ ! -f "${INSTALL_DIR}/persona.json" ]]; then
	install -m 0640 -o "${SWEETTY_USER}" -g "${SWEETTY_USER}" /dev/null "${INSTALL_DIR}/persona.json"
fi

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
log "Systemd slot units"
install -m 0644 "${SCRIPT_DIR}/systemd/sweetty-blue.service" /etc/systemd/system/sweetty-blue.service
install -m 0644 "${SCRIPT_DIR}/systemd/sweetty-green.service" /etc/systemd/system/sweetty-green.service
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
	sd_want="$(grep -E " (\./)?${sd_asset}\$" "${sd_tmp}/checksums.txt" | awk '{print $1}')"
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
systemctl enable nftables
nft -f /etc/nftables.conf
echo "nftables loaded"

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
		TLS_GLOBAL="global(defaultNetstreamDriver=\"gtls\" defaultNetstreamDriverCAFile=\"${LOG_CA_FILE}\")"
		TLS_PARAMS="\n         StreamDriver=\"gtls\" StreamDriverMode=\"1\" StreamDriverAuthMode=\"x509/name\""
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

cat <<EOF

=== Provisioning complete ===

Next:
  1. Reconnect on the admin SSH port if you moved it: ssh -p ${ADMIN_SSH_PORT} ...
  2. Add the deploy public key:
       echo '<deploy pubkey>' >> /home/${DEPLOY_USER}/.ssh/authorized_keys
       chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys
       chown ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh/authorized_keys
  3. Deploy a pinned release (never 'latest'):
       deploy/deploy.sh ${RELEASE_TAG:-vX.Y.Z}
  4. Reach the portal by forwarding the SSH port to its loopback bind:
       ssh -L 8888:127.0.0.1:${PORTAL_PORT:-8888} ${DEPLOY_USER}@host -p ${ADMIN_SSH_PORT}
       then open http://localhost:8888 (no login: SSH key auth is the front door).
EOF
