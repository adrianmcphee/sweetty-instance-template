#!/usr/bin/env bash
#
# Assert every SweeTTY surface profile renders coherently across config.json,
# HAProxy, and nftables. This is the guard against adding a protocol in one layer
# and forgetting the others.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SURFACE="${REPO_ROOT}/provision/render-surface.sh"
NFT="${REPO_ROOT}/provision/render-nftables.sh"
EXAMPLE_ENV="${REPO_ROOT}/sweetty.instance.env.example"
profiles=(web edge infra legacy ftp full)

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

has_port() {
	local ports="$1" want="$2" p
	for p in ${ports}; do
		[[ "${p}" == "${want}" ]] && return 0
	done
	return 1
}

assert_ports_policy() {
	local profile="$1" ports="$2" count=0
	for p in 2375 3306 5555 6379; do
		if has_port "${ports}" "${p}"; then
			count=$((count + 1))
		fi
	done
	if [[ "${profile}" == "full" ]]; then
		[[ "${count}" -eq 4 ]] || {
			echo "surface ${profile}: full must expose Docker, MySQL, ADB, and Redis" >&2
			return 1
		}
	elif [[ "${count}" -eq 4 ]]; then
		echo "surface ${profile}: only full may expose every new service" >&2
		return 1
	fi
	case "${profile}" in
		infra)
			if ! { has_port "${ports}" 2375 && has_port "${ports}" 3306 && has_port "${ports}" 6379 && ! has_port "${ports}" 5555; }; then
				echo "surface infra: want Docker, MySQL, and Redis, not ADB" >&2
				return 1
			fi
			;;
		legacy)
			if ! { has_port "${ports}" 5555 && ! has_port "${ports}" 2375 && ! has_port "${ports}" 3306 && ! has_port "${ports}" 6379; }; then
				echo "surface legacy: want ADB, not Docker, MySQL, or Redis" >&2
				return 1
			fi
			;;
	esac
}

check_config_ports() {
	local file="$1" expected="$2" label="$3"
	python3 - "$file" "$expected" "$label" <<'PY'
import json
import sys

path, expected_raw, label = sys.argv[1:]
expected = [int(x) for x in expected_raw.split()]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
listeners = cfg.get("listeners", [])
got = [int(x["port"]) for x in listeners]
if got != expected:
    raise SystemExit(f"{label}: listener ports {got} != expected {expected}")
if len(got) != len(set(got)):
    raise SystemExit(f"{label}: duplicate listener ports {got}")
valid = {"ftp", "ssh", "telnet", "http", "https", "adb", "mysql", "redis", "docker"}
bad = [x.get("protocol") for x in listeners if x.get("protocol") not in valid]
if bad:
    raise SystemExit(f"{label}: invalid protocols {bad}")
if not any(x.get("protocol") == "http" for x in listeners):
    raise SystemExit(f"{label}: every profile needs one HTTP listener for deploy health")
PY
}

for profile in "${profiles[@]}"; do
	rows="${tmp}/${profile}.rows"
	TOPOLOGY=haproxy SWEETTY_PROFILE="${profile}" "${SURFACE}" rows > "${rows}"
	public_ports="$(TOPOLOGY=haproxy SWEETTY_PROFILE="${profile}" "${SURFACE}" ports)"
	backend_ports="$(awk -F '\t' '{print $4}' "${rows}" | xargs)"
	public_ports_csv="$(TOPOLOGY=haproxy SWEETTY_PROFILE="${profile}" "${SURFACE}" ports-csv)"

	assert_ports_policy "${profile}" "${public_ports}"

	direct_config="${tmp}/${profile}.direct.json"
	haproxy_config="${tmp}/${profile}.haproxy.json"
	TOPOLOGY=direct SWEETTY_PROFILE="${profile}" "${SURFACE}" config > "${direct_config}"
	TOPOLOGY=haproxy SWEETTY_PROFILE="${profile}" "${SURFACE}" config > "${haproxy_config}"
	check_config_ports "${direct_config}" "${public_ports}" "${profile} direct config"
	check_config_ports "${haproxy_config}" "${backend_ports}" "${profile} haproxy config"

	haproxy_file="${tmp}/${profile}.haproxy.cfg"
	TOPOLOGY=haproxy SWEETTY_PROFILE="${profile}" "${SURFACE}" haproxy > "${haproxy_file}"
	while IFS=$'\t' read -r public protocol persona backend rate cur; do
		name="$(awk -v p="${public}" -v proto="${protocol}" '
			BEGIN {
				if (p == 21) print "ftp";
				else if (p == 22) print "ssh";
				else if (p == 23) print "telnet";
				else if (p == 80) print "http";
				else if (p == 443) print "https";
				else if (p == 2323) print "telnet_alt";
				else if (p == 8080) print "http_alt";
				else print proto "_" p;
			}
		')"
		grep -qxF "frontend fe_${name}" "${haproxy_file}" || {
			echo "surface ${profile}: missing HAProxy frontend fe_${name}" >&2
			exit 1
		}
		grep -qxF "    bind :${public}" "${haproxy_file}" || {
			echo "surface ${profile}: missing HAProxy bind :${public}" >&2
			exit 1
		}
		grep -qxF "    server sweetty 127.0.0.1:${backend} send-proxy" "${haproxy_file}" || {
			echo "surface ${profile}: missing HAProxy backend ${backend}" >&2
			exit 1
		}
		: "${persona}" "${rate}" "${cur}"
	done < "${rows}"
	if command -v haproxy >/dev/null 2>&1; then
		haproxy -c -f "${haproxy_file}" >/dev/null
	fi

	nft_file="${tmp}/${profile}.nft"
	OUTPUT="${nft_file}" INSTANCE_ENV="${EXAMPLE_ENV}" SWEETTY_PROFILE="${profile}" "${NFT}" >/dev/null
	grep -qxF "define honeypot_ports = { ${public_ports_csv} }" "${nft_file}" || {
		echo "surface ${profile}: nftables honeypot_ports do not match rendered ports" >&2
		exit 1
	}
	if command -v nft >/dev/null 2>&1; then
		nft -c -f "${nft_file}" >/dev/null
	fi
done

echo "surface profiles render coherently"
