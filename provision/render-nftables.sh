#!/usr/bin/env bash
#
# Render the nftables ruleset from sweetty.instance.env.
#
# nft has native variables, so instead of fragile text substitution this script
# emits a block of `define` lines from the instance config and concatenates the
# static template after it. The result is a single self-contained ruleset that
# `nft -c -f` can validate and `nft -f` can load.
#
# It is deliberately FAIL-CLOSED: rather than render a ruleset whose egress drop
# would target the wrong uid, or whose management rule would open to the world, it
# refuses to write output and exits non-zero, so provision.sh stops before loading
# anything weaker than intended. The single most important control on the box is the
# honeypot user's zero-egress drop; everything here protects it. The only place a
# missing value is tolerated is the local example syntax check (no real
# sweetty.instance.env present), which never reaches a live firewall.
#
# Usage:
#   OUTPUT=/etc/nftables.d/sweetty.nft INSTANCE_ENV=sweetty.instance.env \
#     provision/render-nftables.sh
#
# Defaults: reads sweetty.instance.env (or the .example as a fallback for local
# syntax checks) and writes /tmp/sweetty.nft.rendered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/nftables/sweetty.nft.template"
OUTPUT="${OUTPUT:-/tmp/sweetty.nft.rendered}"

fatal() { echo "render-nftables: FATAL: $*" >&2; exit 1; }
resolve_uid() { id -u "$1" 2>/dev/null || true; }

# Example mode = no real instance env, so we are only syntax-checking locally and
# may fall back to placeholder values that never reach a live firewall.
USING_EXAMPLE=0
INSTANCE_ENV="${INSTANCE_ENV:-${REPO_ROOT}/sweetty.instance.env}"
if [[ ! -f "${INSTANCE_ENV}" ]]; then
	INSTANCE_ENV="${REPO_ROOT}/sweetty.instance.env.example"
	USING_EXAMPLE=1
	echo "render-nftables: no sweetty.instance.env, using the example for a syntax check" >&2
fi
# An explicitly-passed example env is also example mode, so a check can render it
# on a machine that happens to have a real env too (the sweetty user won't exist
# off-host, and example mode uses the nobody uid rather than fail-closing).
if [[ "${INSTANCE_ENV}" == *sweetty.instance.env.example ]]; then
	USING_EXAMPLE=1
fi

# shellcheck disable=SC1090
source "${INSTANCE_ENV}"

# The honeypot user's uid anchors the egress-DENY rule. If it cannot be resolved to
# a real, non-root uid the drop would match nothing, and the host's narrow egress
# allowances would then leak to the honeypot, so fail closed. The one exception is
# example mode, where the user may not exist yet and we only want a syntax check.
sweetty_uid="$(resolve_uid "${SWEETTY_USER:-sweetty}")"
if [[ -z "${sweetty_uid}" ]]; then
	if [[ "${USING_EXAMPLE}" -eq 1 ]]; then
		sweetty_uid=65534 # nobody, only for the local example check
		echo "render-nftables: ${SWEETTY_USER:-sweetty} not found; using nobody uid for the example check" >&2
	else
		fatal "user ${SWEETTY_USER:-sweetty} does not exist; refusing to render a ruleset whose egress drop would target the wrong uid"
	fi
fi
[[ "${sweetty_uid}" =~ ^[0-9]+$ ]] || fatal "resolved sweetty uid '${sweetty_uid}' is not numeric"
if [[ "${USING_EXAMPLE}" -eq 0 && "${sweetty_uid}" -eq 0 ]]; then
	fatal "sweetty resolves to uid 0 (root); SWEETTY_USER must be an unprivileged user"
fi

# Positively uid-scope the egress allowlist, so even if the sweetty drop is ever
# bypassed the honeypot user still cannot use these narrow allowances. :443 (the
# pinned-release pull) is needed by root (apt/system) and the deploy user; log
# shipping by rsyslog, which runs as `syslog` on Debian/Ubuntu (root elsewhere), so
# both uids are allowed. DNS stays destination-pinned but uid-broad on purpose, to
# avoid breaking systemd-resolved's varying caller uid.
deploy_uid="$(resolve_uid "${DEPLOY_USER:-deploy}")"
syslog_uid="$(resolve_uid syslog)"
egress_443_uids="0"
[[ -n "${deploy_uid}" ]] && egress_443_uids="${egress_443_uids}, ${deploy_uid}"
egress_log_uids="0"
[[ -n "${syslog_uid}" ]] && egress_log_uids="${egress_log_uids}, ${syslog_uid}"

# Management source(s). Reject an all-addresses wildcard that would open the admin
# SSH port to the entire internet. The v6 define stays syntactically valid even on
# v4-only hosts (::1 matches nothing reachable, so v6 management stays closed).
operator_ip="${OPERATOR_IP:-203.0.113.10}"
operator_ip6="${OPERATOR_IP6:-::1}"
for _v in operator_ip operator_ip6; do
	_val="${!_v}"
	# Must be a single host or CIDR. Reject empties, and reject range (a-b), set
	# ({...}), or list (a,b) notations and any /0 prefix outright: each is a valid
	# nft spelling of "the whole internet" that a plain "/0" blacklist would miss
	# and that would open admin SSH to everyone.
	[[ -n "${_val// /}" ]] || fatal "${_v} is empty; set the address you connect from"
	case "${_val}" in
	*[-{},]*) fatal "${_v}='${_val}' must be a single host or CIDR, not a range, set, or list" ;;
	esac
	[[ "${_val}" =~ /0+$ ]] && fatal "${_v}='${_val}' is an all-internet wildcard (/0)"
done

# DNS resolvers as an nft set; an empty set is a misconfiguration (it would deny the
# host all DNS and fail nft's own syntax check), so refuse it.
dns_set="$(printf '%s' "${DNS_RESOLVERS:-1.1.1.1}" | tr ',' ' ' | xargs | sed 's/ /, /g')"
[[ -n "${dns_set}" ]] || fatal "DNS_RESOLVERS is empty; refusing to render an empty resolver set"

# Log collector port (the host:port after the colon). Default 6514 (syslog/TLS).
# Validate it so a malformed LOG_ENDPOINT cannot render a range like
# `dport 1-65535 accept`, which would open all TCP egress.
log_port="6514"
if [[ -n "${LOG_ENDPOINT:-}" && "${LOG_ENDPOINT}" == *:* ]]; then
	# A bare (unbracketed) IPv6 host has several colons and no ']', which "##*:"
	# would silently mis-split into a wrong port; require host:port or [v6]:port.
	if [[ "${LOG_ENDPOINT}" != *"]"* && "${LOG_ENDPOINT//[^:]/}" != ":" ]]; then
		fatal "LOG_ENDPOINT='${LOG_ENDPOINT}' looks like a bare IPv6 address; bracket it as [fd00::1]:6514"
	fi
	log_port="${LOG_ENDPOINT##*:}"
fi
if [[ ! "${log_port}" =~ ^[0-9]+$ ]] || ((log_port < 1 || log_port > 65535)); then
	fatal "log port '${log_port}' from LOG_ENDPOINT is not a valid 1-65535 port"
fi

mkdir -p "$(dirname "${OUTPUT}")"
{
	echo "# Rendered from ${INSTANCE_ENV} by render-nftables.sh. Do not edit."
	echo "define operator_ip = ${operator_ip}"
	echo "define operator_ip6 = ${operator_ip6}"
	echo "define admin_ssh_port = ${ADMIN_SSH_PORT:-8088}"
	echo "define honeypot_ports = { 21, 22, 23, 80, 443, 2323, 8080 }"
	echo "define dns_resolvers = { ${dns_set} }"
	echo "define log_port = ${log_port}"
	echo "define sweetty_uid = ${sweetty_uid}"
	echo "define egress_443_uids = { ${egress_443_uids} }"
	echo "define egress_log_uids = { ${egress_log_uids} }"
	echo ""
	cat "${TEMPLATE}"
} >"${OUTPUT}"

echo "render-nftables: wrote ${OUTPUT}"
