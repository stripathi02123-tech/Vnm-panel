#!/usr/bin/env bash
set -Eeuo pipefail

# Stable VNM/HKVM installer entrypoint.
# The main installer is maintained in install-v5.sh.
readonly CORE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install-v5.sh'
readonly TMP="/tmp/vnm-install-v5-$$.sh"

cleanup() {
    rm -f "${TMP}" || true
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || {
    echo '[ERROR] Run as root.' >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    echo '[ERROR] curl is required.' >&2
    exit 1
}

curl -fsSL "${CORE_URL}" -o "${TMP}"
chmod 700 "${TMP}"
exec "${TMP}" "$@"
