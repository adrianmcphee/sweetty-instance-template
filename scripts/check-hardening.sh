#!/usr/bin/env bash
#
# Assert the systemd slot units carry the hardening directives the assume-escape
# threat model depends on. CI syntax-checks the firewall but nothing checks that the
# process sandbox is intact: a typo (NoExecPath=), a line dropped in a merge, or a
# weakened value (ProtectSystem=full instead of strict) still loads and starts, so
# containment silently erodes with the service reporting healthy. This fails the gate
# instead. Pure text assertion, so it runs everywhere (no systemd needed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Directives that must appear verbatim in every slot unit. Exact strings, so a
# weakened value (ProtectSystem=full) fails because the strict form is absent.
required=(
	"NoNewPrivileges=yes"
	"ProtectSystem=strict"
	"ProtectHome=yes"
	"PrivateTmp=yes"
	"ProtectProc=invisible"
	"ProtectKernelModules=yes"
	"ProtectKernelTunables=yes"
	"RestrictNamespaces=yes"
	"RestrictSUIDSGID=yes"
	"LockPersonality=yes"
	"NoExecPaths=/"
	"MemoryDenyWriteExecute=yes"
	"CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
	"SystemCallArchitectures=native"
	"SystemCallFilter=@system-service"
)

fail=0
for unit in sweetty-blue sweetty-green; do
	f="${REPO_ROOT}/provision/systemd/${unit}.service"
	if [[ ! -f "${f}" ]]; then
		echo "MISSING UNIT: ${f}" >&2
		fail=1
		continue
	fi
	for d in "${required[@]}"; do
		if ! grep -qxF "${d}" "${f}"; then
			echo "MISSING: ${unit}.service lacks the exact directive '${d}'" >&2
			fail=1
		fi
	done
	# The capability bounding set must grant ONLY the low-port bind. Any other CAP_
	# token on that line widens what a compromised process could do.
	if grep '^CapabilityBoundingSet=' "${f}" | grep -qE 'CAP_(SYS|DAC|NET_ADMIN|NET_RAW|CHOWN|FOWNER|SETUID|SETGID)'; then
		echo "WIDENED: ${unit}.service CapabilityBoundingSet grants more than CAP_NET_BIND_SERVICE" >&2
		fail=1
	fi
	# The exec allowlist must pin execution to this slot's own binary.
	if ! grep -qxF "ExecPaths=/opt/sweetty/${unit}" "${f}"; then
		echo "MISSING: ${unit}.service must pin ExecPaths to /opt/sweetty/${unit}" >&2
		fail=1
	fi
done

if [[ "${fail}" -ne 0 ]]; then
	echo "systemd hardening check FAILED" >&2
	exit 1
fi
echo "systemd hardening directives present and unweakened"
