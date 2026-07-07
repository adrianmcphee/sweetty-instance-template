#!/usr/bin/env bash
#
# Render the coherent SweeTTY service surface for one instance profile.
#
# One profile drives every place that must agree:
#   - /opt/sweetty/config.json listener ports
#   - HAProxy public frontends and loopback backends
#   - nftables public honeypot port set
#   - bootstrap verification port list

set -euo pipefail

cmd="${1:-}"
profile="${SWEETTY_PROFILE:-web}"
topology="${TOPOLOGY:-haproxy}"
portal_port="${PORTAL_PORT:-8888}"

profiles=(web edge infra legacy ftp full)
random_profiles=(web edge infra legacy ftp)

pick_profile() {
	local i
	i=$((RANDOM % ${#random_profiles[@]}))
	printf '%s\n' "${random_profiles[$i]}"
}

if [[ "${cmd}" == "pick-profile" ]]; then
	pick_profile
	exit 0
fi

if [[ -z "${profile}" || "${profile}" == "random" ]]; then
	profile="$(pick_profile)"
fi

valid_profile() {
	local p="$1" candidate
	for candidate in "${profiles[@]}"; do
		[[ "${candidate}" == "${p}" ]] && return 0
	done
	return 1
}

if ! valid_profile "${profile}"; then
	echo "unknown SWEETTY_PROFILE '${profile}' (want one of: ${profiles[*]}, random)" >&2
	exit 1
fi

case "${topology}" in
	haproxy | direct) ;;
	*) echo "unknown TOPOLOGY '${topology}' (want haproxy or direct)" >&2; exit 1 ;;
esac

profile_rows() {
	case "$1" in
	web)
		cat <<'EOF'
22 ssh -
80 http wordpress
443 https -
8080 http tomcat
EOF
		;;
	edge)
		cat <<'EOF'
22 ssh -
23 telnet cisco
80 http nginx-static
443 https -
EOF
		;;
	infra)
		cat <<'EOF'
22 ssh -
80 http nginx-static
3306 mysql -
2375 docker -
6379 redis -
EOF
		;;
	legacy)
		cat <<'EOF'
21 ftp -
22 ssh -
23 telnet ubuntu
80 http nginx-static
2323 telnet ubuntu
5555 adb -
EOF
		;;
	ftp)
		cat <<'EOF'
21 ftp -
22 ssh -
80 http nginx-static
EOF
		;;
	full)
		cat <<'EOF'
21 ftp -
22 ssh -
23 telnet ubuntu
80 http wordpress
443 https -
2323 telnet ubuntu
3306 mysql -
2375 docker -
5555 adb -
6379 redis -
8080 http tomcat
EOF
		;;
	esac
}

backend_port() {
	local public="$1"
	if [[ "${topology}" == "direct" ]]; then
		printf '%s\n' "${public}"
		return
	fi
	if [[ "${public}" == "2323" ]]; then
		printf '12323\n'
	else
		printf '%s\n' "$((public + 10000))"
	fi
}

rate_limits() {
	case "$1" in
	http | https) printf '400 200\n' ;;
	*) printf '200 100\n' ;;
	esac
}

frontend_name() {
	local public="$1" protocol="$2"
	case "${public}" in
		21) printf 'ftp\n' ;;
		22) printf 'ssh\n' ;;
		23) printf 'telnet\n' ;;
		80) printf 'http\n' ;;
		443) printf 'https\n' ;;
		2323) printf 'telnet_alt\n' ;;
		8080) printf 'http_alt\n' ;;
		*) printf '%s_%s\n' "${protocol}" "${public}" ;;
	esac
}

rows() {
	local public protocol persona backend rate cur
	while read -r public protocol persona; do
		[[ -z "${public}" ]] && continue
		backend="$(backend_port "${public}")"
		read -r rate cur < <(rate_limits "${protocol}")
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${public}" "${protocol}" "${persona}" "${backend}" "${rate}" "${cur}"
	done < <(profile_rows "${profile}")
}

ports() {
	local public protocol persona backend rate cur
	while IFS=$'\t' read -r public protocol persona backend rate cur; do
		printf '%s\n' "${public}"
	done < <(rows)
}

ports_inline() {
	local sep="" p
	while read -r p; do
		printf '%s%s' "${sep}" "${p}"
		sep=" "
	done < <(ports)
	printf '\n'
}

ports_csv() {
	local sep="" p
	while read -r p; do
		printf '%s%s' "${sep}" "${p}"
		sep=", "
	done < <(ports)
	printf '\n'
}

# The loopback backend ports SweeTTY actually listens on. Under haproxy these are
# the 1XXXX backends the edge forwards to; under direct they equal the public
# ports. Verify probes these to prove SweeTTY is serving, not just that the edge
# port is bound.
backend_ports_inline() {
	local sep="" public protocol persona backend rate cur
	while IFS=$'\t' read -r public protocol persona backend rate cur; do
		printf '%s%s' "${sep}" "${backend}"
		sep=" "
	done < <(rows)
	printf '\n'
}

emit_config() {
	local proxy_line console_block comment_line
	proxy_line=""
	console_block=""
	comment_line=""
	if [[ "${topology}" == "haproxy" ]]; then
		comment_line='  "_comment": "SweeTTY config rendered from SWEETTY_PROFILE. Listeners bind loopback backend ports while HAProxy fronts the public honeypot ports and sends the PROXY header.",'
		proxy_line='  "proxy_protocol": true,'
		console_block='  "admin_consoles": [
    { "name": "haproxy", "label": "HAProxy", "target": "http://127.0.0.1:19000/" }
  ],'
	fi
	{
		printf '{\n'
		[[ -n "${comment_line}" ]] && printf '%s\n' "${comment_line}"
		printf '  "portal_port": %s,\n' "${portal_port}"
		printf '  "log_file": "/opt/sweetty/sweetty.log",\n'
		printf '  "record_dir": "/opt/sweetty/recordings",\n'
		printf '  "persona_file": "/opt/sweetty/state/persona.json",\n'
		printf '  "geoip_file": "/opt/sweetty/geo/country-ipv4.csv",\n'
		printf '  "asn_file": "/opt/sweetty/geo/asn-ipv4.csv",\n'
		printf '  "bruteforce": { "enabled": true, "after_tries": 4, "after_seconds": 45, "probability": 0.4 },\n'
		[[ -n "${proxy_line}" ]] && printf '%s\n' "${proxy_line}"
		[[ -n "${console_block}" ]] && printf '%s\n' "${console_block}"
		printf '  "listeners": [\n'
		local sep="" public protocol persona backend rate cur
		while IFS=$'\t' read -r public protocol persona backend rate cur; do
			printf '%s' "${sep}"
			# public_port is the port the world reaches; under haproxy it differs from the
			# loopback backend the process binds, so the console can show the real surface.
			printf '    { "port": %s, "protocol": "%s", "public_port": %s' "${backend}" "${protocol}" "${public}"
			if [[ "${persona}" != "-" ]]; then
				printf ', "persona": "%s"' "${persona}"
			fi
			printf ' }'
			sep=$',\n'
		done < <(rows)
		printf '\n  ]\n}\n'
	}
}

emit_haproxy() {
	cat <<'EOF'
# HAProxy edge for SweeTTY.
#
# Generated from SWEETTY_PROFILE by provision/render-surface.sh. HAProxy fronts
# the public honeypot ports and forwards to the loopback SweeTTY backends with
# PROXY protocol, so SweeTTY records the real attacker source IP.

global
    log /dev/log local0
    maxconn 20000
    user haproxy
    group haproxy
    daemon
    stats socket /run/haproxy/admin.sock mode 660 level operator
    stats timeout 30s

defaults
    log global
    mode tcp
    option dontlognull
    timeout connect 5s
    timeout client 1m
    timeout server 1m
    timeout tunnel 1h

backend st_src
    stick-table type ip size 1m expire 10m store conn_cur,conn_rate(10s)

EOF
	local public protocol persona backend rate cur name
	while IFS=$'\t' read -r public protocol persona backend rate cur; do
		name="$(frontend_name "${public}" "${protocol}")"
		cat <<EOF
frontend fe_${name}
    bind :${public}
    tcp-request connection track-sc0 src table st_src
    tcp-request connection reject if { sc0_conn_rate(st_src) gt ${rate} }
    tcp-request connection reject if { sc0_conn_cur(st_src) gt ${cur} }
    default_backend be_${name}
backend be_${name}
    server sweetty 127.0.0.1:${backend} send-proxy

EOF
	done < <(rows)
	cat <<'EOF'
# The portal is not fronted here. It binds loopback and is reached only by
# forwarding the management SSH port to it.
listen stats
    bind 127.0.0.1:19000
    mode http
    stats enable
    stats uri /dashboard/console/haproxy
    stats refresh 10s
    stats show-node
    stats show-legends
    stats admin if { src 127.0.0.0/8 }
EOF
}

case "${cmd}" in
	profile)
		printf '%s\n' "${profile}"
		;;
	validate-profile)
		printf '%s\n' "${profile}" >/dev/null
		;;
	rows)
		rows
		;;
	ports)
		ports_inline
		;;
	ports-csv)
		ports_csv
		;;
	backend-ports)
		backend_ports_inline
		;;
	config)
		emit_config
		;;
	haproxy)
		emit_haproxy
		;;
	*)
		echo "usage: $0 {profile|pick-profile|validate-profile|rows|ports|ports-csv|backend-ports|config|haproxy}" >&2
		exit 2
		;;
esac
