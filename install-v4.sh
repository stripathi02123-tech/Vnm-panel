#!/usr/bin/env bash

# ============================================================
# HKVM PANEL V3 — FRESH ULTRA INSTALLER V4
# GitHub repo -> Vnm-panel.zip -> extract -> verify -> run
# License is disabled for this development build.
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
CONFIG_DIR='/etc/hkvm'
ENV_FILE="${CONFIG_DIR}/hkvm.env"
SERVICE_NAME='hkvm'
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PID_FILE="${INSTALL_DIR}/hkvm.pid"
LOG_FILE="${LOG_DIR}/hkvm.log"
PANEL_PORT='8080'

TMP_DIR=''
HAS_SYSTEMD='false'

line(){ echo -e "${MAGENTA}============================================================${NC}"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
die(){ error "$*"; exit 1; }

cleanup(){
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then rm -rf "${TMP_DIR}" || true; fi
}
trap cleanup EXIT

on_error(){
  local rc=$?
  error "Installer failed at line ${BASH_LINENO[0]} (exit ${rc})."
  if [[ -f "${LOG_FILE}" ]]; then
    echo '---------------- HKVM LOG ----------------'
    tail -n 160 "${LOG_FILE}" || true
    echo '-------------------------------------------'
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

             HKVM PANEL V3
          FRESH ULTRA INSTALLER

EOF
echo -e "${NC}"
line

# ============================================================
# ENVIRONMENT
# ============================================================

[[ ${EUID} -eq 0 ]] || die 'Please run this installer as root.'
[[ -f /etc/os-release ]] || die 'Unable to detect operating system.'
# shellcheck disable=SC1091
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
apt-get update -y

info 'Installing base dependencies...'
apt-get install -y ca-certificates curl git unzip file lsof procps iproute2 openssl build-essential python3

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  info 'Installing virtualization dependencies...'
  apt-get install -y qemu-system-x86 qemu-utils ovmf cloud-init libvirt-daemon-system libvirt-clients
fi

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
  if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= 20 )); then NODE_OK='true'; fi
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
# STORAGE / BACKUP
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

# Stop systemd service.
if [[ "${HAS_SYSTEMD}" == 'true' ]]; then systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true; fi

# Stop old known standalone PID.
if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ "${OLD_PID}" =~ ^[0-9]+$ ]] && kill -0 "${OLD_PID}" >/dev/null 2>&1; then
    kill "${OLD_PID}" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "${OLD_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${PID_FILE}"
fi

# Clean only HKVM listeners from port 8080.
if command -v lsof >/dev/null 2>&1; then
  mapfile -t LISTENERS < <(lsof -t -nP -iTCP:"${PANEL_PORT}" -sTCP:LISTEN 2>/dev/null || true)
  for PID in "${LISTENERS[@]:-}"; do
    [[ "${PID}" =~ ^[0-9]+$ ]] || continue
    CMD="$(ps -p "${PID}" -o args= 2>/dev/null || true)"
    CWD="$(readlink -f "/proc/${PID}/cwd" 2>/dev/null || true)"
    if [[ "${CWD}" == "${APP_DIR}" || "${CMD}" == *"${APP_DIR}/app.js"* ]]; then
      warn "Stopping old HKVM listener PID ${PID}."
      kill "${PID}" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "${PID}" >/dev/null 2>&1 || true
    else
      die "Port ${PANEL_PORT} is already occupied by another process (PID ${PID})."
    fi
  done
fi

ok 'Storage prepared.'
line

# ============================================================
# GITHUB -> ZIP
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

ZIP_SIZE="$(du -m "${ZIP_FILE}" | awk '{print $1}')"
info "Found ${ZIP_NAME}: ${ZIP_SIZE} MB"
(( ZIP_SIZE >= 1 )) || die 'ZIP is empty or invalid.'

unzip -q "${ZIP_FILE}" -d "${EXTRACT_DIR}"
ok 'ZIP extracted.'
line

# ============================================================
# REAL APPLICATION ROOT
# ============================================================

info 'Detecting real HKVM application root...'

# IMPORTANT: the supplied archive contains an app.js panel entrypoint while
# package.json may have an unrelated npm start script. Therefore app.js is
# intentionally preferred before package.json scripts.
mapfile -t APP_FILES < <(
  find "${EXTRACT_DIR}" -type f -name app.js \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort
)

SOURCE_APP_DIR=''
if [[ "${#APP_FILES[@]}" -gt 0 ]]; then SOURCE_APP_DIR="$(dirname "${APP_FILES[0]}")"; fi

if [[ -z "${SOURCE_APP_DIR}" ]]; then
  mapfile -t PACKAGE_FILES < <(
    find "${EXTRACT_DIR}" -type f -name package.json \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort
  )
  for PKG in "${PACKAGE_FILES[@]}"; do
    DIR="$(dirname "${PKG}")"
    if node -e 'const p=require(process.argv[1]); const s=p.scripts&&p.scripts.start; const m=p.main; process.exit((typeof s==="string"&&s.trim())||(typeof m==="string"&&m.trim())?0:1)' "${PKG}" >/dev/null 2>&1; then
      SOURCE_APP_DIR="${DIR}"
      break
    fi
  done
fi

[[ -n "${SOURCE_APP_DIR}" ]] || die 'Unable to locate the real HKVM application root.'
[[ "${SOURCE_APP_DIR}" != *'/node_modules/'* ]] || die 'Safety failure: application root is inside node_modules.'

info "Application root: ${SOURCE_APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -a "${SOURCE_APP_DIR}/." "${APP_DIR}/"
ok "Application installed into ${APP_DIR}."
line

# ============================================================
# DEPENDENCIES
# ============================================================

cd "${APP_DIR}"
[[ -f package.json ]] || die 'package.json missing from application.'

info 'Installing Node.js dependencies...'
if [[ -f package-lock.json ]]; then
  if ! npm ci --omit=dev; then
    warn 'npm ci failed; retrying npm install.'
    npm install --omit=dev
  fi
else
  npm install --omit=dev
fi

info 'Rebuilding native modules...'
npm rebuild sqlite3 ssh2 >/dev/null 2>&1 || warn 'Native rebuild returned non-zero; continuing to runtime validation.'

ok 'Node.js dependencies installed.'
line

# ============================================================
# LICENSE — DISABLED
# ============================================================

cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
PANEL_NAME=HKVM
SESSION_SECRET=$(openssl rand -hex 32)
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
ok 'Configuration created.'
ok 'License is DISABLED — no license key is required.'
line

# ============================================================
# PANEL ENTRYPOINT
# ============================================================

# NEVER use npm start when app.js exists for this HKVM archive.
if [[ -f "${APP_DIR}/app.js" ]]; then
  MAIN_JS="${APP_DIR}/app.js"
elif [[ -f "${APP_DIR}/server.js" ]]; then
  MAIN_JS="${APP_DIR}/server.js"
elif [[ -f "${APP_DIR}/index.js" ]]; then
  MAIN_JS="${APP_DIR}/index.js"
else
  die 'No supported HKVM panel entrypoint (app.js/server.js/index.js) was found.'
fi

node --check "${MAIN_JS}" || die 'Application syntax check failed.'
info "Panel entrypoint: ${MAIN_JS}"
ok 'Application syntax check passed.'
line

# ============================================================
# CSRF LOGIN FIX
# ============================================================

info 'Applying login CSRF compatibility fix...'
cp -a "${MAIN_JS}" "${BACKUP_DIR}/$(basename "${MAIN_JS}").csrf.$(date +%Y%m%d-%H%M%S).bak"

python3 - "${MAIN_JS}" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

# Add a narrow login exemption at the beginning of csrfProtection.
if 'const __hkvm_login_path =' not in s:
    pat = re.compile(r'(function\s+csrfProtection\s*\([^)]*\)\s*\{)')
    m = pat.search(s)
    if m:
        inject = """\n  const __hkvm_login_path = (req.originalUrl || req.url || req.path || '/').split('?')[0].replace(/\\/+$/, '') || '/';\n  if (req.method === 'POST' && (__hkvm_login_path === '/login' || __hkvm_login_path === '/api/login')) {\n    return next();\n  }\n"""
        s = s[:m.end()] + inject + s[m.end():]
    else:
        set_pat = re.compile(r'(CSRF_EXEMPT_PATHS\s*=\s*new\s+Set\(\[)(.*?)(\]\);)', re.S)
        sm = set_pat.search(s)
        if sm:
            body = sm.group(2)
            if "'/login'" not in body: body += "\n  '/login',"
            if "'/api/login'" not in body: body += "\n  '/api/login',"
            s = s[:sm.start(2)] + body + s[sm.end(2):]

p.write_text(s, encoding='utf-8')
PY

node --check "${MAIN_JS}" || die 'Syntax check failed after CSRF compatibility fix.'
ok 'Login compatibility check passed.'
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
# SYSTEMD OR STANDALONE
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
ExecStart=/usr/bin/node ${MAIN_JS}
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
  systemctl start "${SERVICE_NAME}"
else
  info 'Starting HKVM in standalone/background mode...'
  : > "${LOG_FILE}"
  nohup bash -lc "set -a; source '${ENV_FILE}'; set +a; exec /usr/bin/node '${MAIN_JS}'" >>"${LOG_FILE}" 2>&1 &
  HKVM_PID=$!
  echo "${HKVM_PID}" > "${PID_FILE}"
fi

sleep 5

# ============================================================
# STARTUP DIAGNOSTICS
# ============================================================

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    error 'HKVM service failed to start.'
    systemctl status "${SERVICE_NAME}" --no-pager --full || true
    journalctl -u "${SERVICE_NAME}" -n 200 --no-pager || true
    exit 1
  fi
  ok 'HKVM service is ONLINE.'
else
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
    ok "HKVM process is running (PID $(cat "${PID_FILE}"))."
  else
    error 'HKVM process exited during startup.'
    echo '---------------- HKVM STARTUP LOG ----------------'
    tail -n 200 "${LOG_FILE}" || true
    echo '---------------------------------------------------'
    exit 1
  fi
fi

line

info "Checking panel port ${PANEL_PORT}..."
PANEL_STATUS='OFFLINE'
for _ in {1..20}; do
  if ss -ltn 2>/dev/null | grep -Eq ":${PANEL_PORT}([[:space:]]|$)"; then
    PANEL_STATUS='ONLINE'
    break
  fi
  sleep 1
done

HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PANEL_PORT}/" 2>/dev/null || true)"

if [[ "${PANEL_STATUS}" == 'ONLINE' ]]; then ok "Port ${PANEL_PORT} is listening."; else warn "Port ${PANEL_PORT} is not listening."; fi
if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ && "${HTTP_STATUS}" != '000' ]]; then ok "HTTP health check: ${HTTP_STATUS}"; else warn 'HTTP health check returned no response.'; fi

PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP='YOUR_SERVER_IP'

if [[ "${HAS_SYSTEMD}" == 'true' ]]; then PROCESS='RUNNING'; else PROCESS='RUNNING'; fi

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

  STATUS              : ${PANEL_STATUS}
  LICENSE STATUS      : DISABLED

  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}

  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  ENTRYPOINT          : ${MAIN_JS}
  DATA DIRECTORY      : ${DATA_DIR}
  CONFIGURATION       : ${ENV_FILE}
  SERVICE             : ${SERVICE_NAME}
  PROCESS             : ${PROCESS}
  LOG FILE            : ${LOG_FILE}

──────────────────────────────────────────────────────────────

  START
    $([[ "${HAS_SYSTEMD}" == 'true' ]] && echo "systemctl start ${SERVICE_NAME}" || echo "node ${MAIN_JS}")

  RESTART
    $([[ "${HAS_SYSTEMD}" == 'true' ]] && echo "systemctl restart ${SERVICE_NAME}" || echo "kill \$(cat ${PID_FILE}) && nohup node ${MAIN_JS} >>${LOG_FILE} 2>&1 &")

  STATUS
    $([[ "${HAS_SYSTEMD}" == 'true' ]] && echo "systemctl status ${SERVICE_NAME}" || echo "ps -fp \$(cat ${PID_FILE})")

  LOGS
    tail -f ${LOG_FILE}

──────────────────────────────────────────────────────────────

  LICENSE MODE
    disabled
    No license key is requested by this installer.

  SOURCE
    ${REPO_URL}
    ${ZIP_NAME}

╚════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ "${PANEL_STATUS}" == 'ONLINE' ]]; then
  ok "HKVM Panel is running on port ${PANEL_PORT}."
else
  warn "HKVM installed but port ${PANEL_PORT} is not listening."
  warn "Check: tail -n 200 ${LOG_FILE}"
fi

line
echo -e "${CYAN}HKVM installation finished.${NC}"
