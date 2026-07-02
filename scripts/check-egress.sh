#!/usr/bin/env bash
#
# Assert the rendered nftables ruleset actually DENIES the honeypot user's egress,
# not merely that it parses. firewall-check runs `nft -c` (syntax); this proves the
# single most important control on the box: the sweetty uid drop exists, is ordered
# ABOVE every egress allow, and the sweetty uid is absent from the allowlist sets.
# Someone could reorder the drop below the accepts, or add sweetty to the 443
# allowlist, and the ruleset would still parse; this catches that. Text-based, so it
# runs everywhere (no nft needed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT
# Render from the example env, so the check is deterministic and independent of any
# real instance env on the machine (the real env fail-closes off-host because the
# sweetty user does not exist there). The example uses the nobody uid, which is all
# the ordering and set-membership assertions below need.
OUTPUT="${OUT}" INSTANCE_ENV="${REPO_ROOT}/sweetty.instance.env.example" \
	"${REPO_ROOT}/provision/render-nftables.sh" >/dev/null 2>&1 || {
	echo "render-nftables.sh failed against the example env" >&2
	exit 1
}

line_of() { grep -nF -- "$1" "${OUT}" | head -1 | cut -d: -f1; }

fail=0

# 1. The sweetty egress drop must exist. The single-quoted patterns below hold nft
# variable names ($sweetty_uid, $log_port) that must stay literal, not shell-expand.
# shellcheck disable=SC2016
drop_line="$(grep -n 'skuid \$sweetty_uid' "${OUT}" | grep -i 'drop' | head -1 | cut -d: -f1 || true)"
if [[ -z "${drop_line}" ]]; then
	echo "MISSING: no 'meta skuid \$sweetty_uid ... drop' rule in the rendered ruleset" >&2
	fail=1
fi

# 2. It must be ordered ABOVE every egress allow (a drop after an accept is dead).
# shellcheck disable=SC2016
for allow in 'tcp dport 443 accept' 'dport $log_port accept'; do
	al="$(line_of "${allow}" || true)"
	if [[ -n "${al}" && -n "${drop_line}" && "${drop_line}" -gt "${al}" ]]; then
		echo "ORDER: the sweetty egress drop (line ${drop_line}) is BELOW '${allow}' (line ${al}); it is dead" >&2
		fail=1
	fi
done

# 3. The sweetty uid must not appear in either egress allowlist set.
sweetty_uid="$(grep -E '^define sweetty_uid = ' "${OUT}" | awk '{print $NF}')"
if [[ -n "${sweetty_uid}" ]]; then
	for set_name in egress_443_uids egress_log_uids; do
		set_line="$(grep -E "^define ${set_name} = " "${OUT}" || true)"
		if grep -qE "(^|[^0-9])${sweetty_uid}([^0-9]|$)" <<<"${set_line}"; then
			echo "LEAK: sweetty uid ${sweetty_uid} is present in ${set_name} (${set_line}); it could ride that egress allow" >&2
			fail=1
		fi
	done
else
	echo "WARNING: could not extract sweetty_uid from the rendered ruleset" >&2
fi

# 4. Both hook policies that matter must be drop by default.
for policy in 'hook input priority filter; policy drop' 'hook output priority filter; policy drop'; do
	if ! grep -qF -- "${policy}" "${OUT}"; then
		echo "MISSING: default '${policy}' not found; the chain is not deny-by-default" >&2
		fail=1
	fi
done

if [[ "${fail}" -ne 0 ]]; then
	echo "egress-deny check FAILED" >&2
	exit 1
fi
echo "egress-deny: sweetty uid dropped, ordered above the allowlist, and absent from it"
