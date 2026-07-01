#!/usr/bin/env bash
#
# One-shot provision + deploy for a host you already have root on: the SSH-driven
# equivalent of the cloud-init first boot. Run it from a checkout of this repo on
# the host (cloud-init clones the repo first and then calls this). It is
# idempotent and safe to re-run.
#
#   sudo INSTANCE_ENV=/path/to/sweetty.instance.env \
#        DEPLOY_PUBKEY=/path/to/deploy.pub \
#        ./bootstrap.sh
#
# It provisions the host, installs the deploy public key, deploys the pinned
# release, and then VERIFIES the honeypot is actually serving before reporting
# success. Any failed step exits non-zero, so an operator (or cloud-init) sees a
# break instead of a half-built box that claims to be done.
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || {
	echo "bootstrap.sh must run as root" >&2
	exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ENV="${INSTANCE_ENV:-${REPO_ROOT}/sweetty.instance.env}"
[[ -f "${INSTANCE_ENV}" ]] || {
	echo "instance env not found: ${INSTANCE_ENV}" >&2
	echo "copy sweetty.instance.env.example to sweetty.instance.env and fill it in" >&2
	exit 1
}
# shellcheck disable=SC1090
source "${INSTANCE_ENV}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sweetty}"
: "${RELEASE_TAG:?set RELEASE_TAG in the instance env}"

echo "### bootstrap: provision ###"
INSTANCE_ENV="${INSTANCE_ENV}" "${REPO_ROOT}/provision/provision.sh"

echo "### bootstrap: deploy key ###"
DEPLOY_PUBKEY="${DEPLOY_PUBKEY:-/root/deploy.pub}"
if [[ -f "${DEPLOY_PUBKEY}" ]]; then
	install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
	install -m 0600 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_PUBKEY}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
	echo "installed deploy key for ${DEPLOY_USER}"
else
	echo "no deploy key at ${DEPLOY_PUBKEY}; ${DEPLOY_USER} will have no key (set DEPLOY_PUBKEY)" >&2
fi

echo "### bootstrap: deploy ${RELEASE_TAG} (as ${DEPLOY_USER}) ###"
# Place the repo in the deploy user's home and run the FIRST deploy as that user,
# identical to every later `make deploy`. Running it as root instead would leave
# root-owned state (the deploy staging dir) that then blocks a deploy-user
# re-deploy, and it means ongoing deploys are exercised from the very first one.
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
DEPLOY_HOME="${DEPLOY_HOME:-/home/${DEPLOY_USER}}"
DEPLOY_CHECKOUT="${DEPLOY_HOME}/sweetty-instance-template"
rm -rf "${DEPLOY_CHECKOUT}"
cp -a "${REPO_ROOT}" "${DEPLOY_CHECKOUT}"
cp -f "${INSTANCE_ENV}" "${DEPLOY_CHECKOUT}/sweetty.instance.env"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_CHECKOUT}"
runuser -u "${DEPLOY_USER}" -- env INSTANCE_ENV="${DEPLOY_CHECKOUT}/sweetty.instance.env" \
	"${DEPLOY_CHECKOUT}/deploy/deploy.sh" "${RELEASE_TAG}"

echo "### bootstrap: verify ###"
active="$(cat "${INSTALL_DIR}/.active-slot" 2>/dev/null || echo blue)"
rc=0
if systemctl is-active "sweetty-${active}.service" >/dev/null 2>&1; then
	echo "  slot ${active}: active"
else
	echo "  slot ${active}: NOT active" >&2
	rc=1
fi
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo 000)"
if [[ "${code}" == "200" ]]; then
	echo "  http 127.0.0.1:80 -> 200"
else
	echo "  http 127.0.0.1:80 -> ${code} (want 200)" >&2
	rc=1
fi
for p in 21 22 23 80 443 2323 8080; do
	if ss -tln 2>/dev/null | grep -q ":${p} "; then
		echo "  port ${p}: bound"
	else
		echo "  port ${p}: NOT bound" >&2
		rc=1
	fi
done
if [[ "${rc}" -ne 0 ]]; then
	echo "### bootstrap: VERIFY FAILED (honeypot not fully serving) ###" >&2
	exit 1
fi
echo "### bootstrap: complete; honeypot live on slot ${active} ###"
# End on the exact admin port and copy-paste commands provision.sh resolved, so
# whoever ran this knows precisely how to reconnect and open the console.
echo
if [[ -r /root/sweetty-access.txt ]]; then
	cat /root/sweetty-access.txt
else
	echo "admin SSH port: ${ADMIN_SSH_PORT:-see /root/sweetty.instance.env}"
fi
