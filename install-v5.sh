#!/usr/bin/env bash

# ============================================================
# VNM PANEL V3 — FRESH ULTRA INSTALLER V5
# GitHub ZIP -> extract -> install -> configure -> run
#
# Development build:
#   LICENSE_MODE=disabled
#   No license prompt
# ============================================================

set -Eeuo pipefail

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
WHITE='\e[1;37m'
NC='\e[0m'

REPO_URL='https://github.com/stripathi02123-tech/Vnm-panel.git'
ZIP_NAME='Vnm-panel.zip'

INSTALL_DIR='/opt/hkvm'
APP_DIR="${INSTALL_DIR}/app"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
CONFIG_DIR='/etc/hkvm'
ENV_FILE="${CONFIG_DIR}/hkvm.env"
LOG_FILE="${LOG_DIR}/hkvm.log"
PID_FILE="${INSTALL_DIR}/hkvm.pid"
SERVICE_NAME='hkvm'
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PANEL_PORT='8080'

TMP_DIR=''
HAS_SYSTEMD='false'
NODE_BIN=''
NPM_BIN=''
MAIN_JS=''

line(){ echo -e "${MAGENTA}============================================================${NC}"; }
info(){ echo -e "${CYAN}[VNM PANEL][INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[VNM PANEL][OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[VNM PANEL][WARNING]${NC} $*"; }
error(){ echo -e "${RED}[VNM PANEL][ERROR]${NC} $*"; }
die(){ error "$*"; exit 1; }

cleanup(){
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}" || true
  fi
}
trap cleanup EXIT

on_error(){
  local rc=$?
  error "Installer failed at line ${BASH_LINENO[0]} (exit ${rc})."
  if [[ -f "${LOG_FILE}" ]]; then
    echo '---------------- VNM PANEL LOG ----------------'
    tail -n 160 "${LOG_FILE}" || true
    echo '-----------------------------------------------'
  fi
  exit "${rc}"
}
trap on_error ERR

clear 2>/dev/null || true
echo -e "${CYAN}"
cat <<'EOF'

██╗  ██╗██╗  ██╗██╗   ██╗███╗   ███╗
██║ ██╔╝██║ ██╔╝██║   ██║████╗ ████║
█████╔╝ █████╔╝ ██║   ██║██╔████╔██║
██╔═██╗ ██╔═██╗ ╚██╗ ██╔╝██║╚██╔╝██║
██║  ██╗██║  ██╗ ╚████╔╝ ██║ ╚═╝ ██║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝

             VNM PANEL V3
          FRESH ULTRA INSTALLER V5
EOF
echo -e "${NC}"
line

# ============================================================
# ROOT / OS
# ============================================================

[[ ${EUID} -eq 0 ]] || die 'Please run this installer as root.'
[[ -f /etc/os-release ]] || die 'Unable to detect operating system.'
source /etc/os-release

info "Operating System : ${PRETTY_NAME:-unknown}"
info "Architecture     : $(uname -m)"
info "Kernel           : $(uname -r)"

[[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || die "Unsupported OS: ${ID:-unknown}."

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD='true'
  ok 'systemd detected — service mode enabled.'
else
  warn 'systemd not detected — standalone/background mode enabled.'
  info 'This is normal in GitHub Codespaces and containers.'
fi
line

# ============================================================
# PACKAGES
# ============================================================

export DEBIAN_FRONTEND=noninteractive
info 'Updating package lists...'
apt-get update -y

info 'Installing base dependencies...'
apt-get install -y \
  ca-certificates curl git unzip file lsof procps iproute2 \
  openssl build-essential python3

# VM runtime packages are useful on a real VM host. Avoid pulling the large
# QEMU/libvirt stack into Codespaces where /dev/kvm is normally unavailable.
if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  info 'Installing virtualization dependencies...'
  apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-init libvirt-daemon-system libvirt-clients
else
  warn 'Skipping libvirt/QEMU host packages because systemd is unavailable.'
fi

ok 'System dependencies installed.'
line

# ============================================================
# NODE / NPM
# ============================================================

NODE_OK='false'
if command -v node >/dev/null 2>&1; then
  NODE_VERSION="$(node -v | sed 's/^v//')"
  NODE_MAJOR="${NODE_VERSION%%.*}"
  NODE_BIN="$(command -v node)"
  NODE_BIN="$(readlink -f "${NODE_BIN}" 2>/dev/null || echo "${NODE_BIN}")"
  info "Detected Node.js: v${NODE_VERSION}"
  if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= 20 )); then
    NODE_OK='true'
  fi
fi

if [[ "${NODE_OK}" != 'true' ]]; then
  info 'Installing Node.js 22...'
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  NODE_BIN="$(command -v node)"
  NODE_BIN="$(readlink -f "${NODE_BIN}" 2>/dev/null || echo "${NODE_BIN}")"
fi

command -v node >/dev/null 2>&1 || die 'Node.js installation failed.'
command -v npm >/dev/null 2>&1 || die 'npm installation failed.'
NODE_BIN="$(readlink -f "$(command -v node)" 2>/dev/null || command -v node)"
NPM_BIN="$(readlink -f "$(command -v npm)" 2>/dev/null || command -v npm)"

[[ -x "${NODE_BIN}" ]] || die "Resolved Node binary is not executable: ${NODE_BIN}"
[[ -x "${NPM_BIN}" ]] || die "Resolved npm binary is not executable: ${NPM_BIN}"

ok "Node.js: $("${NODE_BIN}" -v) | npm: $("${NPM_BIN}" -v)"
info "Node binary: ${NODE_BIN}"
line

# ============================================================
# STORAGE / OLD INSTANCE
# ============================================================

info "Preparing ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${CONFIG_DIR}"
chmod 755 "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${BACKUP_DIR}" "${CONFIG_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

if [[ -f "${ENV_FILE}" ]]; then
  cp -a "${ENV_FILE}" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"
  ok 'Existing configuration backed up.'
fi

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ "${OLD_PID}" =~ ^[0-9]+$ ]]; then
    kill "${OLD_PID}" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      kill -0 "${OLD_PID}" >/dev/null 2>&1 || break
      sleep 0.2
    done
    kill -9 "${OLD_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${PID_FILE}"
fi

# Clean an old HKVM listener only if it actually belongs to /opt/hkvm/app.
if command -v lsof >/dev/null 2>&1; then
  mapfile -t LISTEN_PIDS < <(lsof -t -nP -iTCP:"${PANEL_PORT}" -sTCP:LISTEN 2>/dev/null || true)
  for LPID in "${LISTEN_PIDS[@]:-}"; do
    [[ "${LPID}" =~ ^[0-9]+$ ]] || continue
    CMD="$(ps -p "${LPID}" -o args= 2>/dev/null || true)"
    CWD="$(readlink -f "/proc/${LPID}/cwd" 2>/dev/null || true)"
    if [[ "${CWD}" == "${APP_DIR}" ]] || [[ "${CMD}" == *"${APP_DIR}/app.js"* ]]; then
      warn "Stopping old VNM Panel listener PID ${LPID} on port ${PANEL_PORT}."
      kill "${LPID}" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "${LPID}" >/dev/null 2>&1 || break
        sleep 0.2
      done
      kill -9 "${LPID}" >/dev/null 2>&1 || true
    else
      die "Port ${PANEL_PORT} is already used by another process (PID ${LPID})."
    fi
  done
fi

ok 'Storage prepared.'
line

# ============================================================
# GITHUB -> ZIP
# ============================================================

TMP_DIR="$(mktemp -d -t vnm-panel-installer-XXXXXX)"
REPO_DIR="${TMP_DIR}/repo"
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "${EXTRACT_DIR}"

info 'Cloning VNM Panel repository...'
git clone --depth 1 --single-branch "${REPO_URL}" "${REPO_DIR}"
ok 'Repository cloned.'

ZIP_FILE="${REPO_DIR}/${ZIP_NAME}"
if [[ ! -f "${ZIP_FILE}" ]]; then
  ZIP_FILE="$(find "${REPO_DIR}" -type f -name "${ZIP_NAME}" -not -path '*/.git/*' -print -quit 2>/dev/null || true)"
fi
[[ -n "${ZIP_FILE}" && -f "${ZIP_FILE}" ]] || die "${ZIP_NAME} was not found in the repository."

ZIP_SIZE_MB="$(du -m "${ZIP_FILE}" | awk '{print $1}')"
info "Found ${ZIP_NAME}: ${ZIP_SIZE_MB} MB"
(( ZIP_SIZE_MB >= 1 )) || die 'ZIP is empty or invalid.'

info 'Extracting application...'
unzip -q "${ZIP_FILE}" -d "${EXTRACT_DIR}"
ok 'ZIP extracted.'
line

# ============================================================
# APPLICATION ROOT
# ============================================================

info 'Detecting real VNM Panel application root...'

mapfile -t APP_FILES < <(
  find "${EXTRACT_DIR}" -type f -name app.js \
    -not -path '*/node_modules/*' -not -path '*/.git/*' \
    -print | sort
)

SOURCE_APP_DIR=''
if [[ "${#APP_FILES[@]}" -gt 0 ]]; then
  SOURCE_APP_DIR="$(dirname "${APP_FILES[0]}")"
fi

if [[ -z "${SOURCE_APP_DIR}" ]]; then
  mapfile -t PACKAGE_FILES < <(
    find "${EXTRACT_DIR}" -type f -name package.json \
      -not -path '*/node_modules/*' -not -path '*/.git/*' \
      -print | sort
  )
  for PKG in "${PACKAGE_FILES[@]}"; do
    DIR="$(dirname "${PKG}")"
    if node -e 'const p=require(process.argv[1]); const m=p.main; process.exit(typeof m==="string"&&m.trim()?0:1)' "${PKG}" >/dev/null 2>&1; then
      SOURCE_APP_DIR="${DIR}"
      break
    fi
  done
fi

[[ -n "${SOURCE_APP_DIR}" ]] || die 'Unable to locate the real VNM Panel application root.'
[[ "${SOURCE_APP_DIR}" != *'/node_modules/'* ]] || die 'Safety failure: application root is inside node_modules.'

info "Application root: ${SOURCE_APP_DIR}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -a "${SOURCE_APP_DIR}/." "${APP_DIR}/"

[[ -f "${APP_DIR}/app.js" ]] || die 'Expected VNM Panel app.js was not found after extraction.'

ok "Application installed into ${APP_DIR}."
line

# ============================================================
# DEPENDENCIES
# ============================================================

cd "${APP_DIR}"
[[ -f package.json ]] || die 'package.json missing from application.'

info 'Installing Node.js dependencies...'
if [[ -f package-lock.json ]]; then
  if ! "${NPM_BIN}" ci --omit=dev; then
    warn 'npm ci failed; retrying with npm install.'
    "${NPM_BIN}" install --omit=dev
  fi
else
  "${NPM_BIN}" install --omit=dev
fi

info 'Rebuilding native modules...'
"${NPM_BIN}" rebuild sqlite3 ssh2 >/dev/null 2>&1 || warn 'Native module rebuild returned non-zero; runtime validation will catch failures.'

ok 'Node.js dependencies installed.'
line

# ============================================================
# DEVELOPMENT LICENSE: DISABLED
# ============================================================

SESSION_SECRET="$(openssl rand -hex 32)"
[[ -n "${SESSION_SECRET}" ]] || die 'Failed to generate session secret.'

# Generate a shell-safe env file. Values containing spaces MUST be quoted.
cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
PANEL_NAME="VNM Panel"
SESSION_SECRET=${SESSION_SECRET}
LICENSE_MODE=disabled
LICENSE_KEY=
HKVM_INSTALL_DIR=${INSTALL_DIR}
HKVM_APP_DIR=${APP_DIR}
HKVM_DATA_DIR=${DATA_DIR}
HKVM_LOG_DIR=${LOG_DIR}
EOF

chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}"
ln -sfn "${ENV_FILE}" "${APP_DIR}/.env"

# Validate the generated env before sourcing it later in standalone mode.
if ! bash -n "${ENV_FILE}"; then
  die "Generated VNM Panel environment file is invalid: ${ENV_FILE}"
fi

ok 'Configuration created.'
ok 'License is DISABLED — no license key is required.'
line

# ============================================================
# ENTRYPOINT / SYNTAX
# ============================================================

MAIN_JS="${APP_DIR}/app.js"

info "Panel entrypoint: ${MAIN_JS}"
"${NODE_BIN}" --check "${MAIN_JS}" || die 'Application syntax check failed.'
ok 'Application syntax check passed.'
line

# ============================================================
# BEST-EFFORT LOGIN COMPATIBILITY PATCH
# ============================================================

info 'Checking login/CSRF compatibility...'

cp -a "${MAIN_JS}" "${BACKUP_DIR}/app.js.preinstall.$(date +%Y%m%d-%H%M%S).bak"

python3 - "${MAIN_JS}" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
pattern = re.compile(r'function\s+csrfProtection\s*\(\s*req\s*,\s*res\s*,\s*next\s*\)\s*\{', re.S)
m = pattern.search(s)

if m:
    brace = s.find('{', m.start())
    depth = 0
    end = None
    for i in range(brace, len(s)):
        ch = s[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit('Could not safely parse csrfProtection')

    new = '''function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  const requestPath = (req.originalUrl || req.url || req.path || '/').split('?')[0].replace(/\\/+$/, '') || '/';
  const isLogin = requestPath === '/login' || requestPath === '/api/login';

  if (!mutating || isLogin || requestPath.startsWith('/api/auth/')) {
    return next();
  }

  const headerToken = req.get('x-csrf-token');
  if (!headerToken || headerToken !== req.session.csrfToken) {
    console.warn(`[CSRF] Rejected ${req.method} ${requestPath} (bad/missing token) from ${req.ip}`);
    return res.status(403).json({ error: 'Invalid or missing CSRF token' });
  }

  next();
}'''
    s = s[:m.start()] + new + s[end:]
    p.write_text(s, encoding='utf-8')
    print('PATCHED_CSRF_FUNCTION')
else:
    print('NO_NAMED_CSRF_FUNCTION')
PY

"${NODE_BIN}" --check "${MAIN_JS}" || die 'Application syntax check failed after login compatibility patch.'
ok 'Login compatibility check completed.'
line

# ============================================================
# FIREWALL
# ============================================================

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ============================================================
# SYSTEMD / STANDALONE
# ============================================================

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  info 'Creating systemd service...'
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VNM Panel V3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${MAIN_JS}
Restart=always
RestartSec=5
User=root
Group=root
LimitNOFILE=1048576
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${SERVICE_FILE}"
  systemd-analyze verify "${SERVICE_FILE}" || die 'systemd service validation failed.'
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
  : > "${LOG_FILE}"
  systemctl restart "${SERVICE_NAME}"
  sleep 5

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok 'VNM Panel service is ONLINE.'
  else
    error 'VNM Panel service failed to start.'
    systemctl status "${SERVICE_NAME}" --no-pager --full || true
    journalctl -u "${SERVICE_NAME}" -n 200 --no-pager || true
    exit 1
  fi
else
  info 'Starting VNM Panel in standalone/background mode...'
  : > "${LOG_FILE}"

  set -a
  source "${ENV_FILE}"
  set +a

  nohup "${NODE_BIN}" "${MAIN_JS}" >>"${LOG_FILE}" 2>&1 &
  VNM_PANEL_PID=$!
  echo "${VNM_PANEL_PID}" > "${PID_FILE}"

  sleep 5

  if kill -0 "${VNM_PANEL_PID}" >/dev/null 2>&1; then
    ok "VNM Panel process is running (PID ${VNM_PANEL_PID})."
  else
    error 'VNM Panel process exited during startup.'
    echo '---------------- VNM PANEL STARTUP LOG ----------------'
    tail -n 240 "${LOG_FILE}" || true
    echo '--------------------------------------------------------'
    exit 1
  fi
fi

line

# ============================================================
# HEALTH CHECKS
# ============================================================

info "Checking panel port ${PANEL_PORT}..."
PANEL_STATUS='OFFLINE'

for _ in {1..20}; do
  if ss -ltn 2>/dev/null | grep -Eq ":${PANEL_PORT}([[:space:]]|$)"; then
    PANEL_STATUS='ONLINE'
    break
  fi
  sleep 1
done

if [[ "${PANEL_STATUS}" == 'ONLINE' ]]; then
  ok "Port ${PANEL_PORT} is listening."
else
  warn "Port ${PANEL_PORT} is not listening."
fi

HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PANEL_PORT}/" 2>/dev/null || true)"

if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ && "${HTTP_STATUS}" != '000' ]]; then
  ok "HTTP health check returned ${HTTP_STATUS}."
else
  warn 'HTTP health check did not return a response.'
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP='YOUR_SERVER_IP'

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  PROCESS_STATUS='RUNNING'
  MODE='SYSTEMD'
else
  PROCESS_STATUS='RUNNING'
  MODE='STANDALONE'
fi

# ============================================================
# FINAL SCREEN
# ============================================================

clear 2>/dev/null || true
echo -e "${GREEN}"
cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                    VNM PANEL V3                            ║
║                  INSTALLATION COMPLETE                    ║
╚════════════════════════════════════════════════════════════╝

  STATUS              : ${PANEL_STATUS}
  LICENSE STATUS      : DISABLED
  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}

  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  ENTRYPOINT          : ${MAIN_JS}
  DATA DIRECTORY      : ${DATA_DIR}
  CONFIGURATION       : ${ENV_FILE}
  SERVICE             : ${SERVICE_NAME}
  PROCESS             : ${PROCESS_STATUS}
  MODE                : ${MODE}
  NODE BINARY         : ${NODE_BIN}
  LOG FILE            : ${LOG_FILE}

──────────────────────────────────────────────────────────────

  VPS SERVICE COMMANDS

    systemctl start ${SERVICE_NAME}
    systemctl stop ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f

  STANDALONE / CODESPACES

    cat ${PID_FILE}
    tail -f ${LOG_FILE}

──────────────────────────────────────────────────────────────

  SOURCE REPOSITORY

    ${REPO_URL}

  ZIP SOURCE

    ${ZIP_NAME}

  LICENSE

    DISABLED — no key is required for this development build.

╚════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ "${PANEL_STATUS}" == 'ONLINE' ]]; then
  ok "VNM Panel is running on port ${PANEL_PORT}."
else
  warn "VNM Panel installed, but port ${PANEL_PORT} is not listening yet."
  warn "Check: tail -n 240 ${LOG_FILE}"
fi

line
echo -e "${CYAN}VNM Panel V5 installation finished.${NC}"
