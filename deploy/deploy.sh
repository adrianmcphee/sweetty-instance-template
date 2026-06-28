#!/usr/bin/env bash
#
# Deploy a pinned SweeTTY release into the inactive slot.
#
#   deploy/deploy.sh v0.3.0
#
# What it does:
#   1. Refuses to run without an explicit tag (never 'latest').
#   2. Pulls sweetty_<ver>_linux_<arch>.tar.gz and checksums.txt from the
#      product repo's GitHub Releases for that tag.
#   3. Verifies the artifact against checksums.txt before anything is installed.
#   4. Installs the verified binary into the inactive slot and re-grants the
#      low-port capability.
#   5. Hands off to slotdeploy, which starts the new slot, health-checks it,
#      stops the old one, and flips the active marker.
#
# Run it as the deploy user (it uses the narrow sudo grants from provision.sh).
# Provide slotdeploy on PATH, or set SLOTDEPLOY_BIN to its location.

set -euo pipefail

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
	echo "usage: deploy/deploy.sh <release-tag>   (for example v0.3.0)" >&2
	exit 1
fi
if [[ "${TAG}" == "latest" ]]; then
	echo "refusing to deploy 'latest'. Pin an explicit release tag." >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTANCE_ENV="${INSTANCE_ENV:-${REPO_ROOT}/sweetty.instance.env}"
if [[ -f "${INSTANCE_ENV}" ]]; then
	# shellcheck disable=SC1090
	source "${INSTANCE_ENV}"
fi
SWEETTY_REPO="${SWEETTY_REPO:-adrianmcphee/sweetty}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sweetty}"
SLOTDEPLOY_CONFIG="${SLOTDEPLOY_CONFIG:-${SCRIPT_DIR}/slotdeploy.yaml}"

# Locate slotdeploy.
SLOTDEPLOY_BIN="${SLOTDEPLOY_BIN:-}"
if [[ -z "${SLOTDEPLOY_BIN}" ]]; then
	for candidate in "$(command -v slotdeploy 2>/dev/null || true)" "${HOME}/bin/slotdeploy" /usr/local/bin/slotdeploy; do
		if [[ -n "${candidate}" && -x "${candidate}" ]]; then SLOTDEPLOY_BIN="${candidate}"; break; fi
	done
fi
if [[ -z "${SLOTDEPLOY_BIN}" || ! -x "${SLOTDEPLOY_BIN}" ]]; then
	echo "slotdeploy not found. Install it on PATH or set SLOTDEPLOY_BIN." >&2
	echo "  go build -o ~/bin/slotdeploy github.com/adrianmcphee/slotdeploy/cmd/slotdeploy" >&2
	exit 1
fi

# Resolve architecture to the release naming.
case "$(uname -m)" in
	x86_64|amd64) ARCH="amd64" ;;
	aarch64|arm64) ARCH="arm64" ;;
	*) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

VER="${TAG#v}"
ASSET="sweetty_${VER}_linux_${ARCH}.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "=== Fetching ${ASSET} from ${SWEETTY_REPO}@${TAG} ==="
if command -v gh >/dev/null 2>&1; then
	# gh handles private repos and auth transparently.
	gh release download "${TAG}" --repo "${SWEETTY_REPO}" \
		--pattern "${ASSET}" --pattern "checksums.txt" --dir "${WORK}"
else
	base="https://github.com/${SWEETTY_REPO}/releases/download/${TAG}"
	curl -fsSL "${base}/${ASSET}" -o "${WORK}/${ASSET}"
	curl -fsSL "${base}/checksums.txt" -o "${WORK}/checksums.txt"
fi

echo "=== Verifying checksum ==="
# Tolerate either a bare name or a ./-prefixed one in checksums.txt, so the verify
# works across release builds that differ in that detail.
if ! grep -E " (\./)?${ASSET}\$" "${WORK}/checksums.txt" >/dev/null; then
	echo "no checksum entry for ${ASSET} in checksums.txt" >&2
	exit 1
fi
(
	cd "${WORK}"
	grep -E " (\./)?${ASSET}\$" checksums.txt | sha256sum -c -
)
echo "checksum OK"

echo "=== Extracting binary ==="
tar -xzf "${WORK}/${ASSET}" -C "${WORK}"
if [[ ! -f "${WORK}/sweetty" ]]; then
	echo "archive did not contain a 'sweetty' binary" >&2
	exit 1
fi

# Stage the verified binary at the fixed path the deploy sudoers grant reads
# from. The deploy user owns this staging dir (no sudo needed); the next step is
# a narrowly-granted "sudo install" that copies this fixed source into the slot
# as root:sweetty, which is the only privileged action in the deploy.
install -d -m 0755 /tmp/sweetty-deploy
install -m 0755 "${WORK}/sweetty" /tmp/sweetty-deploy/sweetty

# Determine the inactive slot the same way slotdeploy will.
ACTIVE="$(cat "${INSTALL_DIR}/.active-slot" 2>/dev/null || echo blue)"
if [[ "${ACTIVE}" == "blue" ]]; then TARGET="green"; else TARGET="blue"; fi
echo "=== Installing into the ${TARGET} slot (active is ${ACTIVE}) ==="

sudo install -o root -g sweetty -m 0750 /tmp/sweetty-deploy/sweetty "${INSTALL_DIR}/sweetty-${TARGET}"
sudo setcap cap_net_bind_service=+ep "${INSTALL_DIR}/sweetty-${TARGET}"

# slotdeploy needs its env file to exist (it may be empty).
touch "${INSTALL_DIR}/deploy/slotdeploy.env"

echo "=== Swapping slots with slotdeploy ==="
"${SLOTDEPLOY_BIN}" deploy --config "${SLOTDEPLOY_CONFIG}" --image-tag "${TAG}"

echo "=== Deployed ${TAG} into ${TARGET}. Active slot is now ${TARGET}. ==="
"${SLOTDEPLOY_BIN}" status --config "${SLOTDEPLOY_CONFIG}" || true
