#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM / HKVM PANEL — DIRECT INSTALLER
# Runs the production installer, then displays admin credentials directly.
# License remains disabled by the underlying installer.
# ============================================================================

readonly REPO_URL='https://github.com/stripathi02123-tech/Vnm-panel.git'
readonly CORE_INSTALLER_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install.sh'
readonly INSTALLER='/tmp/hkvm-install.sh'
readonly CREDENTIALS_FILE='/opt/hkvm/admin-credentials.txt'

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info(){ printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
error(){ printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
die(){ error "$*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die 'Run this installer as root.'
command -v curl >/dev/null 2>&1 || die 'curl is required.'

info 'Downloading the current production installer...'
curl -fsSL "${CORE_INSTALLER_URL}" -o "${INSTALLER}"
chmod 700 "${INSTALLER}"
ok 'Production installer downloaded.'

# Run the existing tested installer without modifying its source.
"${INSTALLER}"

# The production installer creates this only after a successful admin setup.
[[ -f "${CREDENTIALS_FILE}" ]] || die 'Installation succeeded, but admin credentials were not generated.'

USERNAME="$(sed -n 's/^Username:[[:space:]]*//p' "${CREDENTIALS_FILE}" | head -n1)"
PASSWORD="$(sed -n 's/^Password:[[:space:]]*//p' "${CREDENTIALS_FILE}" | head -n1)"

[[ -n "${USERNAME}" ]] || die 'Admin username could not be read.'
[[ -n "${PASSWORD}" ]] || die 'Admin password could not be read.'

printf '\n%b\n' "${GREEN}"
cat <<EOF
╔════════════════════════════════════════════════════════════╗
║                 ADMIN LOGIN CREDENTIALS                   ║
╚════════════════════════════════════════════════════════════╝

  Username : ${USERNAME}
  Password : ${PASSWORD}

  Panel    : http://localhost:8080

  Save these credentials securely and change the password
  after your first login.

╚════════════════════════════════════════════════════════════╝
EOF
printf '%b\n' "${NC}"

ok 'Admin credentials displayed directly.'
rm -f "${INSTALLER}"
