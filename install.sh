#!/usr/bin/env bash

# ============================================================
# HKVM PANEL V3 — CLEAN ULTRA INSTALLER
# GitHub ZIP -> extract -> install -> configure -> start
#
# This development installer intentionally DISABLES licensing.
# No license key is requested.
# ============================================================

set -Eeuo pipefail

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
NC='\e[0m'

REPO_URL='https://github.com/stripathi02123-tech/Vnm-panel.git'
ZIP_NAME='Vnm-panel.zip'

INSTALL_DIR='/opt/hkvm'
APP_DIR="${INSTALL_DIR}/app"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
ETC_DIR='/etc/hkvm'
ENV_FILE="${ETC_DIR}/hkvm.env"
LOG_FILE="${LOG_DIR}/hkvm.log"
PID_FILE="${INSTALL_DIR}/hkvm.pid"
SERVICE_NAME='hkvm'
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PANEL_PORT="${PANEL_PORT:-8080}"
NODE_MIN_MAJOR=20

TMP_DIR=''
HAS_SYSTEMD='false'

line(){ echo -e "${MAGENTA}============================================================${NC}"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
die(){ error "$*"; exit 1; }

cleanup(){
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

on_error(){
    local rc=$?
    error "Installer failed at line ${BASH_LINENO[0]} (exit ${rc})."
    if [[ -f "${LOG_FILE}" ]]; then
        echo '---------------- HKVM LOG ----------------'
        tail -n 150 "${LOG_FILE}" || true
        echo '-------------------------------------------'
    fi
    exit "${rc}"
}
trap on_error ERR

# ============================================================
# HEADER
# ============================================================

clear 2>/dev/null || true
echo -e "${CYAN}"
cat <<'EOF'

██╗  ██╗██╗  ██╗██╗   ██╗███╗   ███╗
██║ ██╔╝██║ ██╔╝██║   ██║████╗ ████║
█████╔╝ █████╔╝ ██║   ██║██╔████╔██║
██╔═██╗ ██╔═██╗ ╚██╗ ██╔╝██║╚██╔╝██║
██║  ██╗██║  ██╗ ╚████╔╝ ██║ ╚═╝ ██║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝

             HKVM PANEL V3
          CLEAN ULTRA INSTALLER

EOF
echo -e "${NC}"
line

# ============================================================
# BASIC ENVIRONMENT
# ============================================================

[[ "${EUID}" -eq 0 ]] || die 'Run this installer as root.'
[[ -f /etc/os-release ]] || die 'Cannot detect operating system.'
# shellcheck disable=SC1091
source /etc/os-release

info "Operating System : ${PRETTY_NAME:-unknown}"
info "Architecture     : $(uname -m)"
info "Kernel           : $(uname -r)"

case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Unsupported operating system: ${ID:-unknown}. Use Ubuntu or Debian." ;;
esac

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD='true'
    ok 'systemd detected — service mode enabled.'
else
    HAS_SYSTEMD='false'
    warn 'systemd not detected — standalone/background mode enabled.'
fi

line

# ============================================================
# SYSTEM PACKAGES
# ============================================================

export DEBIAN_FRONTEND=noninteractive

info 'Updating package lists...'
apt-get update -y

info 'Installing system dependencies...'
apt-get install -y \
    ca-certificates \
    curl \
    git \
    unzip \
    file \
    lsof \
    procps \
    iproute2 \
    openssl \
    build-essential \
    python3 \
    qemu-system-x86 \
    qemu-utils \
    cloud-init

ok 'System dependencies installed.'
line

# ============================================================
# NODE.JS
# ============================================================

NODE_OK='false'
if command -v node >/dev/null 2>&1; then
    NODE_VERSION="$(node -v | sed 's/^v//')"
    NODE_MAJOR="${NODE_VERSION%%.*}"
    info "Detected Node.js: v${NODE_VERSION}"
    if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= NODE_MIN_MAJOR )); then
        NODE_OK='true'
    fi
fi

if [[ "${NODE_OK}" != 'true' ]]; then
    info 'Installing Node.js 22...'
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

command -v node >/dev/null 2>&1 || die 'Node.js installation failed.'
command -v npm >/dev/null 2>&1 || die 'npm installation failed.'
ok "Node.js: $(node -v) | npm: $(npm -v)"
line

# ============================================================
# STORAGE / EXISTING INSTALL
# ============================================================

info "Preparing ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${ETC_DIR}"
chmod 755 "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${BACKUP_DIR}" "${ETC_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

if [[ -f "${ENV_FILE}" ]]; then
    cp -a "${ENV_FILE}" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"
    ok 'Existing HKVM configuration backed up.'
fi

# Stop the known service and the known standalone process.
if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

if [[ -f "${PID_FILE}" ]]; then
    OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ "${OLD_PID}" =~ ^[0-9]+$ ]]; then
        kill "${OLD_PID}" >/dev/null 2>&1 || true
        for _ in {1..15}; do
            kill -0 "${OLD_PID}" >/dev/null 2>&1 || break
            sleep 0.2
        done
        kill -9 "${OLD_PID}" >/dev/null 2>&1 || true
    fi
    rm -f "${PID_FILE}"
fi

# If port 8080 is occupied, terminate only a process clearly belonging to HKVM.
if command -v lsof >/dev/null 2>&1; then
    mapfile -t PIDS < <(lsof -t -nP -iTCP:"${PANEL_PORT}" -sTCP:LISTEN 2>/dev/null || true)
    for LISTEN_PID in "${PIDS[@]:-}"; do
        [[ "${LISTEN_PID}" =~ ^[0-9]+$ ]] || continue
        CMD="$(ps -p "${LISTEN_PID}" -o args= 2>/dev/null || true)"
        CWD="$(readlink -f "/proc/${LISTEN_PID}/cwd" 2>/dev/null || true)"
        if [[ "${CWD}" == "${APP_DIR}" ]] || [[ "${CMD}" == *"${APP_DIR}/app.js"* ]]; then
            warn "Stopping old HKVM listener PID ${LISTEN_PID} on port ${PANEL_PORT}."
            kill "${LISTEN_PID}" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "${LISTEN_PID}" >/dev/null 2>&1 || true
        else
            die "Port ${PANEL_PORT} is already used by another process (PID ${LISTEN_PID})."
        fi
    done
fi

ok 'Storage prepared.'
line

# ============================================================
# DOWNLOAD / EXTRACT
# ============================================================

TMP_DIR="$(mktemp -d -t hkvm-installer-XXXXXX)"
REPO_DIR="${TMP_DIR}/repo"
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "${EXTRACT_DIR}"

info 'Cloning HKVM repository...'
git clone --depth 1 --single-branch "${REPO_URL}" "${REPO_DIR}"
ok 'Repository cloned.'

ZIP_FILE="${REPO_DIR}/${ZIP_NAME}"
if [[ ! -f "${ZIP_FILE}" ]]; then
    ZIP_FILE="$(find "${REPO_DIR}" -type f -name "${ZIP_NAME}" -not -path '*/.git/*' -print -quit 2>/dev/null || true)"
fi
[[ -n "${ZIP_FILE}" && -f "${ZIP_FILE}" ]] || die "${ZIP_NAME} was not found in the repository."

ZIP_SIZE_MB="$(du -m "${ZIP_FILE}" | awk '{print $1}')"
info "Found ${ZIP_NAME}: ${ZIP_SIZE_MB} MB"
(( ZIP_SIZE_MB >= 1 )) || die 'ZIP file is empty or invalid.'

info 'Extracting application...'
unzip -q "${ZIP_FILE}" -d "${EXTRACT_DIR}"
ok 'ZIP extracted.'
line

# ============================================================
# APPLICATION ROOT DETECTION
# ============================================================

info 'Detecting real HKVM application root...'

mapfile -t PACKAGE_FILES < <(
    find "${EXTRACT_DIR}" \
        -type f \
        -name package.json \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -print | sort
)

[[ "${#PACKAGE_FILES[@]}" -gt 0 ]] || die 'No package.json found outside node_modules.'

SOURCE_APP_DIR=''

# Prefer a package with a real start script.
for PKG in "${PACKAGE_FILES[@]}"; do
    DIR="$(dirname "${PKG}")"
    [[ "${DIR}" == *'/node_modules/'* ]] && continue
    if node -e 'const p=require(process.argv[1]); const s=p.scripts&&p.scripts.start; process.exit(typeof s==="string"&&s.trim()?0:1)' "${PKG}" >/dev/null 2>&1; then
        SOURCE_APP_DIR="${DIR}"
        break
    fi
done

# Then prefer a package with a main entry.
if [[ -z "${SOURCE_APP_DIR}" ]]; then
    for PKG in "${PACKAGE_FILES[@]}"; do
        DIR="$(dirname "${PKG}")"
        [[ "${DIR}" == *'/node_modules/'* ]] && continue
        if node -e 'const p=require(process.argv[1]); const m=p.main; process.exit(typeof m==="string"&&m.trim()?0:1)' "${PKG}" >/dev/null 2>&1; then
            SOURCE_APP_DIR="${DIR}"
            break
        fi
    done
fi

# Last fallback: normal Node entry file, never under node_modules.
if [[ -z "${SOURCE_APP_DIR}" ]]; then
    mapfile -t ENTRY_FILES < <(
        find "${EXTRACT_DIR}" \
            -type f \
            \( -name app.js -o -name server.js -o -name index.js -o -name main.js \) \
            -not -path '*/node_modules/*' \
            -not -path '*/.git/*' \
            -print | sort
    )
    [[ "${#ENTRY_FILES[@]}" -gt 0 ]] && SOURCE_APP_DIR="$(dirname "${ENTRY_FILES[0]}")"
fi

[[ -n "${SOURCE_APP_DIR}" ]] || die 'Unable to find HKVM application source.'
[[ "${SOURCE_APP_DIR}" != *'/node_modules/'* ]] || die 'Safety failure: selected application is inside node_modules.'

info "Application root: ${SOURCE_APP_DIR}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -a "${SOURCE_APP_DIR}/." "${APP_DIR}/"
ok "Application installed into ${APP_DIR}."
line

# ============================================================
# NODE DEPENDENCIES
# ============================================================

cd "${APP_DIR}"
[[ -f package.json ]] || die 'package.json is missing after extraction.'

info 'Installing Node.js dependencies...'
if [[ -f package-lock.json ]]; then
    if ! npm ci --omit=dev; then
        warn 'npm ci failed; retrying with npm install.'
        npm install --omit=dev
    fi
else
    npm install --omit=dev
fi

info 'Rebuilding native modules...'
npm rebuild sqlite3 ssh2 >/dev/null 2>&1 || warn 'Native module rebuild returned non-zero; runtime diagnostics will catch startup problems.'

ok 'Node.js dependencies installed.'
line

# ============================================================
# LOGIN / CSRF FIX
# ============================================================

info 'Applying login compatibility check...'

APP_JS=''
for CANDIDATE in app.js server.js index.js main.js; do
    if [[ -f "${APP_DIR}/${CANDIDATE}" ]]; then
        APP_JS="${APP_DIR}/${CANDIDATE}"
        break
    fi
done

[[ -n "${APP_JS}" ]] || die 'Could not locate the main application JavaScript file.'

cp -a "${APP_JS}" "${BACKUP_DIR}/$(basename "${APP_JS}").$(date +%Y%m%d-%H%M%S).bak"

python3 - "${APP_JS}" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
src = path.read_text(encoding='utf-8')

replacement = r'''function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  const requestPath = (req.originalUrl || req.url || req.path || '/').split('?')[0].replace(/\/+$/, '') || '/';
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

pattern = re.compile(r'function\s+csrfProtection\(req,\s*res,\s*next\)\s*\{.*?\n\}', re.S)
match = pattern.search(src)

if match:
    src = src[:match.start()] + replacement + src[match.end():]
else:
    # If there is no named function, make both login routes part of the exemption set.
    set_pattern = re.compile(r'const\s+CSRF_EXEMPT_PATHS\s*=\s*new\s+Set\(\[(.*?)\]\);', re.S)
    sm = set_pattern.search(src)
    if sm:
        body = sm.group(1)
        if "'/login'" not in body:
            body += "\n  '/login',"
        if "'/api/login'" not in body:
            body += "\n  '/api/login',"
        src = src[:sm.start(1)] + body + src[sm.end(1):]

path.write_text(src, encoding='utf-8')
PY

node --check "${APP_JS}" || die 'Application JavaScript syntax check failed after compatibility patch.'
ok 'Application syntax check passed.'
line

# ============================================================
# LICENSE OFF + CONFIGURATION
# ============================================================

SESSION_SECRET="$(openssl rand -hex 32)"
[[ -n "${SESSION_SECRET}" ]] || die 'Unable to generate session secret.'

# License intentionally disabled. There is NO prompt and NO key.
LICENSE_MODE='disabled'
LICENSE_KEY=''

info 'Writing HKVM configuration...'
cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
PANEL_NAME=HKVM
HKVM_DATA_DIR=${DATA_DIR}
SESSION_SECRET=${SESSION_SECRET}
LICENSE_MODE=disabled
LICENSE_KEY=
HKVM_INSTALL_DIR=${INSTALL_DIR}
HKVM_APP_DIR=${APP_DIR}
HKVM_LOG_DIR=${LOG_DIR}
EOF

chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}"
ln -sfn "${ENV_FILE}" "${APP_DIR}/.env"

ok 'Configuration created.'
ok 'License is DISABLED — no license key is required.'
line

# ============================================================
# START COMMAND
# ============================================================

START_SCRIPT="$(node -e 'const p=require("./package.json"); process.stdout.write((p.scripts&&p.scripts.start)||"")' 2>/dev/null || true)"
MAIN_FILE="$(node -e 'const p=require("./package.json"); process.stdout.write(p.main||"")' 2>/dev/null || true)"

if [[ -n "${START_SCRIPT}" ]]; then
    EXEC_START='npm start'
elif [[ -n "${MAIN_FILE}" && -f "${APP_DIR}/${MAIN_FILE}" ]]; then
    EXEC_START="node ${APP_DIR}/${MAIN_FILE}"
else
    ENTRY=''
    for CANDIDATE in app.js server.js index.js main.js; do
        [[ -f "${APP_DIR}/${CANDIDATE}" ]] && { ENTRY="${APP_DIR}/${CANDIDATE}"; break; }
    done
    [[ -n "${ENTRY}" ]] || die 'No application start command found.'
    EXEC_START="node ${ENTRY}"
fi

info "Start command: ${EXEC_START}"

# ============================================================
# START
# ============================================================

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
    info 'Creating systemd service...'
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HKVM Panel V3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env bash -lc 'exec ${EXEC_START}'
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
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    : > "${LOG_FILE}"
    systemctl start "${SERVICE_NAME}"
    sleep 5

    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        error 'HKVM service failed to start.'
        systemctl status "${SERVICE_NAME}" --no-pager --full || true
        echo
        journalctl -u "${SERVICE_NAME}" -n 200 --no-pager || true
        exit 1
    fi

    ok 'HKVM service is ONLINE.'
    RUN_MODE='SYSTEMD'
else
    info 'Starting HKVM in standalone/background mode...'
    : > "${LOG_FILE}"
    cd "${APP_DIR}"
    nohup bash -lc "set -a; source '${ENV_FILE}'; set +a; exec ${EXEC_START}" >>"${LOG_FILE}" 2>&1 &
    HKVM_PID=$!
    echo "${HKVM_PID}" > "${PID_FILE}"
    sleep 5

    if ! kill -0 "${HKVM_PID}" >/dev/null 2>&1; then
        error 'HKVM process exited during startup.'
        echo '---------------- HKVM STARTUP LOG ----------------'
        tail -n 200 "${LOG_FILE}" || true
        echo '---------------------------------------------------'
        exit 1
    fi

    ok "HKVM process is running (PID ${HKVM_PID})."
    RUN_MODE='STANDALONE'
fi

line

# ============================================================
# HEALTH CHECK
# ============================================================

info "Checking TCP port ${PANEL_PORT}..."
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
    warn "Port ${PANEL_PORT} is not listening yet."
fi

HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PANEL_PORT}/login" 2>/dev/null || true)"

if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ && "${HTTP_STATUS}" != '000' ]]; then
    ok "HTTP login page responded with ${HTTP_STATUS}."
else
    warn 'HTTP login health check did not return a normal response.'
fi

# ============================================================
# PUBLIC IP
# ============================================================

PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP='YOUR_SERVER_IP'

# ============================================================
# FINAL SCREEN
# ============================================================

clear 2>/dev/null || true
echo -e "${GREEN}"
cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                    HKVM PANEL V3                           ║
║                  INSTALLATION COMPLETE                    ║
╚════════════════════════════════════════════════════════════╝

  PANEL STATUS        : ${PANEL_STATUS}
  HTTP LOGIN          : ${HTTP_STATUS}
  LICENSE             : DISABLED
  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}

  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  DATA DIRECTORY      : ${DATA_DIR}
  CONFIGURATION       : ${ENV_FILE}
  LOG FILE            : ${LOG_FILE}
  RUN MODE            : ${RUN_MODE}

──────────────────────────────────────────────────────────────

  COMMANDS

  systemd VPS:
    systemctl start ${SERVICE_NAME}
    systemctl stop ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f

  Standalone/Codespaces:
    cat ${PID_FILE}
    tail -f ${LOG_FILE}

──────────────────────────────────────────────────────────────

  LICENSE MODE

    disabled

  No license key is requested or required by this installer.

──────────────────────────────────────────────────────────────

  SOURCE REPOSITORY

    ${REPO_URL}

  SOURCE ZIP

    ${ZIP_NAME}

╚════════════════════════════════════════════════════════════╝
EOF

echo -e "${NC}"

if [[ "${PANEL_STATUS}" == 'ONLINE' ]]; then
    ok "HKVM Panel is running on port ${PANEL_PORT}."
else
    warn "HKVM is installed but port ${PANEL_PORT} is offline."
    warn "Check: tail -n 200 ${LOG_FILE}"
fi

line
echo -e "${CYAN}HKVM installation finished.${NC}"
