#!/usr/bin/env bash

# ============================================================
# HKVM PANEL V3 — ULTRA INSTALLER
# GitHub ZIP based installer
# clone -> extract -> detect -> install -> patch -> run
# ============================================================

set -Eeuo pipefail

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; BLUE='\e[1;34m'
CYAN='\e[1;36m'; MAGENTA='\e[1;35m'; WHITE='\e[1;37m'; NC='\e[0m'

APP_NAME="HKVM"
SERVICE_NAME="hkvm"
REPO_URL="https://github.com/stripathi02123-tech/Vnm-panel.git"
ZIP_NAME="Vnm-panel.zip"

INSTALL_DIR="/opt/hkvm"
APP_DIR="${INSTALL_DIR}/app"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
ETC_DIR="/etc/hkvm"
ENV_FILE="${ETC_DIR}/hkvm.env"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PID_FILE="${INSTALL_DIR}/hkvm.pid"
LOG_FILE="${LOG_DIR}/hkvm.log"

PANEL_PORT="${PANEL_PORT:-8080}"
PANEL_NAME="${PANEL_NAME:-HKVM}"
NODE_MIN_MAJOR=20
# Development/testing default: NO license key prompt.
LICENSE_MODE="${LICENSE_MODE:-disabled}"
LICENSE_KEY="${LICENSE_KEY:-}"

TMP_DIR=""
HAS_SYSTEMD="false"

line(){ echo -e "${MAGENTA}============================================================${NC}"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
die(){ error "$*"; exit 1; }

cleanup(){ [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true; }
trap cleanup EXIT

on_error(){
  local code=$?
  error "Installer failed at line ${BASH_LINENO[0]} (exit ${code})."
  [[ -f "${LOG_FILE}" ]] || exit "${code}"
  echo "---------------- HKVM LOG ----------------"
  tail -n 100 "${LOG_FILE}" || true
  echo "--------------------------------------------"
  exit "${code}"
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
          ULTRA INSTALLER
EOF
echo -e "${NC}"
line

[[ ${EUID} -eq 0 ]] || die "Please run this installer as root."
ok "Root access detected."
[[ -f /etc/os-release ]] || die "Unable to detect operating system."
source /etc/os-release
info "Operating System : ${PRETTY_NAME:-unknown}"
info "Architecture     : $(uname -m)"
info "Kernel           : $(uname -r)"

if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
  warn "This installer is designed for Debian/Ubuntu."
  read -r -p "Continue anyway? [y/N]: " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || die "Installation cancelled."
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD="true"
  ok "systemd detected — service mode enabled."
else
  warn "systemd not detected — standalone/background mode enabled."
  info "This is expected in GitHub Codespaces and containers."
fi
line

export DEBIAN_FRONTEND=noninteractive
command -v apt-get >/dev/null 2>&1 || die "APT package manager is required."
info "Updating package lists..."
apt-get update -y
info "Installing required packages..."
apt-get install -y ca-certificates curl git unzip file lsof procps iproute2 sudo openssl build-essential python3
ok "Base dependencies installed."
line

NODE_OK="false"
if command -v node >/dev/null 2>&1; then
  NODE_VERSION="$(node -v | sed 's/^v//')"
  NODE_MAJOR="${NODE_VERSION%%.*}"
  info "Detected Node.js: v${NODE_VERSION}"
  if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= NODE_MIN_MAJOR )); then
    NODE_OK="true"
  fi
fi
if [[ "${NODE_OK}" != "true" ]]; then
  info "Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
command -v node >/dev/null 2>&1 || die "Node.js installation failed."
command -v npm >/dev/null 2>&1 || die "npm installation failed."
ok "Node.js: $(node -v) | npm: $(npm -v)"
line

info "Preparing HKVM directories..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${ETC_DIR}"
chmod 755 "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${BACKUP_DIR}" "${ETC_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"
ok "HKVM directories prepared."

if [[ -f "${ENV_FILE}" ]]; then
  cp -a "${ENV_FILE}" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"
  ok "Existing configuration backed up."
fi

stop_old(){
  if [[ "${HAS_SYSTEMD}" == "true" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ "${old_pid}" =~ ^[0-9]+$ ]] && kill -0 "${old_pid}" >/dev/null 2>&1; then
      kill "${old_pid}" >/dev/null 2>&1 || true
      for _ in {1..20}; do kill -0 "${old_pid}" >/dev/null 2>&1 || break; sleep 0.2; done
      kill -9 "${old_pid}" >/dev/null 2>&1 || true
    fi
    rm -f "${PID_FILE}"
  fi
  while read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill "${pid}" >/dev/null 2>&1 || true
  done < <(pgrep -f '^node /opt/hkvm/app/app\.js$' 2>/dev/null || true)
}
stop_old
line

TMP_DIR="$(mktemp -d -t hkvm-installer-XXXXXX)"
REPO_DIR="${TMP_DIR}/repo"
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"

info "Cloning HKVM repository..."
git clone --depth 1 --single-branch "${REPO_URL}" "${REPO_DIR}"
ok "Repository cloned."

ZIP_FILE="${REPO_DIR}/${ZIP_NAME}"
if [[ ! -f "${ZIP_FILE}" ]]; then ZIP_FILE="$(find "${REPO_DIR}" -type f -name "${ZIP_NAME}" -print -quit 2>/dev/null || true)"; fi
[[ -n "${ZIP_FILE}" && -f "${ZIP_FILE}" ]] || die "${ZIP_NAME} was not found in the repository."
ZIP_SIZE_MB="$(du -m "${ZIP_FILE}" | awk '{print $1}')"
info "Found ${ZIP_NAME} (${ZIP_SIZE_MB} MB)."
(( ZIP_SIZE_MB >= 1 )) || die "ZIP file is empty or invalid."
ok "ZIP validation passed."
line

info "Extracting ${ZIP_NAME}..."
unzip -q "${ZIP_FILE}" -d "${EXTRACT_DIR}"
ok "ZIP extracted."

info "Detecting real HKVM Node.js application..."
mapfile -t PACKAGE_FILES < <(find "${EXTRACT_DIR}" -type f -name package.json -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort)
[[ "${#PACKAGE_FILES[@]}" -gt 0 ]] || die "No application package.json found outside node_modules."

SOURCE_APP_DIR=""
for candidate in "${PACKAGE_FILES[@]}"; do
  candidate_dir="$(dirname "${candidate}")"
  [[ "${candidate_dir}" == *"/node_modules/"* ]] && continue
  if node -e 'const p=require(process.argv[1]); const s=p.scripts&&p.scripts.start; const m=p.main; process.exit((typeof s==="string"&&s.trim())||(typeof m==="string"&&m.trim())?0:1)' "${candidate}" >/dev/null 2>&1; then
    SOURCE_APP_DIR="${candidate_dir}"
    break
  fi
done

if [[ -z "${SOURCE_APP_DIR}" ]]; then
  mapfile -t ENTRY_FILES < <(find "${EXTRACT_DIR}" -type f \( -name app.js -o -name server.js -o -name index.js -o -name main.js \) -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort)
  [[ "${#ENTRY_FILES[@]}" -gt 0 ]] && SOURCE_APP_DIR="$(dirname "${ENTRY_FILES[0]}")"
fi

[[ -n "${SOURCE_APP_DIR}" ]] || die "Unable to locate the real HKVM application source."
[[ "${SOURCE_APP_DIR}" != *"/node_modules/"* ]] || die "Safety check: application is inside node_modules."
info "Detected application directory: ${SOURCE_APP_DIR}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -a "${SOURCE_APP_DIR}/." "${APP_DIR}/"
ok "Application installed into ${APP_DIR}."
line

cd "${APP_DIR}"
[[ -f package.json ]] || die "package.json missing after extraction."

info "Installing Node.js dependencies..."
if [[ -f package-lock.json ]]; then
  if ! npm ci --omit=dev; then
    warn "npm ci failed; retrying with npm install."
    npm install --omit=dev
  fi
else
  npm install --omit=dev
fi

info "Rebuilding native modules when present..."
npm rebuild sqlite3 ssh2 >/dev/null 2>&1 || warn "Native module rebuild returned non-zero; startup diagnostics will verify the result."
ok "Node.js dependencies installed."
line

# ============================================================
# AUTOMATIC LOGIN/CSRF COMPATIBILITY PATCH
# ============================================================

info "Checking login/CSRF compatibility..."
APP_JS=""
for candidate in app.js server.js index.js; do
  [[ -f "${APP_DIR}/${candidate}" ]] && { APP_JS="${APP_DIR}/${candidate}"; break; }
done
[[ -n "${APP_JS}" ]] || die "Main application JavaScript file not found."

cp -a "${APP_JS}" "${BACKUP_DIR}/app.js.$(date +%Y%m%d-%H%M%S).bak"

python3 - "${APP_JS}" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
s = path.read_text(encoding="utf-8")

replacement = r'''function csrfProtection(req, res, next) {
  const mutating = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method);
  const rawPath = (req.originalUrl || req.url || req.path || '/').split('?')[0];
  const normalizedPath = rawPath.replace(/\/+$/, '') || '/';
  const loginPath = normalizedPath === '/login' || normalizedPath === '/api/login';

  if (!mutating || loginPath || normalizedPath.startsWith('/api/auth/')) {
    return next();
  }

  const headerToken = req.get('x-csrf-token');
  if (!headerToken || headerToken !== req.session.csrfToken) {
    console.warn(`[CSRF] Rejected ${req.method} ${normalizedPath} (bad/missing token) from ${req.ip}`);
    return res.status(403).json({ error: 'Invalid or missing CSRF token' });
  }

  next();
}'''

pattern = re.compile(r"function\s+csrfProtection\(req,\s*res,\s*next\)\s*\{.*?\n\}", re.S)
m = pattern.search(s)
if m:
    s = s[:m.start()] + replacement + s[m.end():]
else:
    setp = re.compile(r"const\s+CSRF_EXEMPT_PATHS\s*=\s*new\s+Set\(\[(.*?)\]\);", re.S)
    sm = setp.search(s)
    if sm:
        body = sm.group(1)
        if "'/login'" not in body: body += "\n  '/login',"
        if "'/api/login'" not in body: body += "\n  '/api/login',"
        s = s[:sm.start(1)] + body + s[sm.end(1):]
path.write_text(s, encoding="utf-8")
PY

if grep -Fq "const loginPath = normalizedPath === '/login' || normalizedPath === '/api/login';" "${APP_JS}"; then
  ok "Login CSRF compatibility verified."
else
  warn "CSRF source pattern was different; inspect runtime logs if login still fails."
fi
line

# ============================================================
# CONFIGURATION — LICENSE OFF BY DEFAULT
# ============================================================

if [[ -f "${ENV_FILE}" ]]; then
  OLD_MODE="$(grep '^LICENSE_MODE=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  OLD_KEY="$(grep '^LICENSE_KEY=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  [[ -n "${OLD_MODE}" ]] && LICENSE_MODE="${OLD_MODE}"
  [[ -n "${OLD_KEY}" ]] && LICENSE_KEY="${OLD_KEY}"
fi

# No prompt. Development default is disabled.
[[ "${LICENSE_MODE}" == "required" && -z "${LICENSE_KEY}" ]] && die "LICENSE_MODE=required but LICENSE_KEY is empty."
SESSION_SECRET="$(openssl rand -hex 32)"

cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
PANEL_NAME=${PANEL_NAME}
HKVM_DATA_DIR=${DATA_DIR}
SESSION_SECRET=${SESSION_SECRET}
LICENSE_MODE=${LICENSE_MODE}
LICENSE_KEY=${LICENSE_KEY}
HKVM_INSTALL_DIR=${INSTALL_DIR}
HKVM_APP_DIR=${APP_DIR}
HKVM_LOG_DIR=${LOG_DIR}
EOF
chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}"
ln -sfn "${ENV_FILE}" "${APP_DIR}/.env"
ok "Configuration created. License mode: ${LICENSE_MODE}"
line

# ============================================================
# START COMMAND
# ============================================================

START_SCRIPT="$(node -e 'const p=require("./package.json"); process.stdout.write((p.scripts&&p.scripts.start)||"")' 2>/dev/null || true)"
MAIN_FILE="$(node -e 'const p=require("./package.json"); process.stdout.write((p.main)||"")' 2>/dev/null || true)"

if [[ -n "${START_SCRIPT}" ]]; then
  EXEC_START="npm start"
  info "Using npm start."
elif [[ -n "${MAIN_FILE}" && -f "${APP_DIR}/${MAIN_FILE}" ]]; then
  EXEC_START="node ${APP_DIR}/${MAIN_FILE}"
  info "Using package.json main: ${MAIN_FILE}"
else
  die "No valid npm start script or package.json main entry found."
fi

# ============================================================
# FIREWALL
# ============================================================

if command -v ufw >/dev/null 2>&1; then ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi

# ============================================================
# START
# ============================================================

if [[ "${HAS_SYSTEMD}" == "true" ]]; then
  info "Creating systemd service..."
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HKVM Panel V3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env bash -lc '${EXEC_START}'
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
  systemctl restart "${SERVICE_NAME}"
else
  info "Starting HKVM in standalone/background mode..."
  : > "${LOG_FILE}"
  cd "${APP_DIR}"
  nohup bash -lc "set -a; source '${ENV_FILE}'; set +a; exec ${EXEC_START}" >>"${LOG_FILE}" 2>&1 &
  HKVM_PID=$!
  echo "${HKVM_PID}" > "${PID_FILE}"
fi

sleep 5

# ============================================================
# DEEP STARTUP DIAGNOSTICS
# ============================================================

if [[ "${HAS_SYSTEMD}" == "true" ]]; then
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    error "HKVM service failed to start."
    systemctl status "${SERVICE_NAME}" --no-pager --full || true
    journalctl -u "${SERVICE_NAME}" -n 200 --no-pager || true
    exit 1
  fi
  ok "HKVM service is ONLINE."
else
  if [[ ! -f "${PID_FILE}" ]] || ! kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
    error "HKVM process exited during startup."
    echo "---------------- HKVM STARTUP LOG ----------------"
    tail -n 250 "${LOG_FILE}" || true
    echo "---------------------------------------------------"
    exit 1
  fi
  ok "HKVM process is running (PID $(cat "${PID_FILE}"))."
fi

line
info "Checking panel port ${PANEL_PORT}..."
PANEL_STATUS="OFFLINE"
for _ in {1..20}; do
  if ss -ltn 2>/dev/null | grep -Eq ":${PANEL_PORT}([[:space:]]|$)"; then PANEL_STATUS="ONLINE"; break; fi
  sleep 1
done

if [[ "${PANEL_STATUS}" != "ONLINE" ]]; then
  error "HKVM process is running but port ${PANEL_PORT} is not listening."
  echo "---------------- HKVM LOG ----------------"
  tail -n 250 "${LOG_FILE}" || true
  echo "-------------------------------------------"
  exit 1
fi
ok "Port ${PANEL_PORT} is listening."

HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PANEL_PORT}/" 2>/dev/null || true)"
if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ && "${HTTP_STATUS}" != "000" ]]; then
  ok "HTTP health check returned ${HTTP_STATUS}."
else
  warn "HTTP health check did not return a normal response."
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="YOUR_SERVER_IP"

if [[ "${LICENSE_MODE}" == "disabled" ]]; then LICENSE_STATUS="DISABLED"; else LICENSE_STATUS="CONFIGURED"; fi
if [[ "${HAS_SYSTEMD}" == "true" ]]; then MODE="SYSTEMD"; else MODE="STANDALONE"; fi

clear 2>/dev/null || true
echo -e "${GREEN}"
cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                    HKVM PANEL V3                           ║
║                  INSTALLATION COMPLETE                    ║
╚════════════════════════════════════════════════════════════╝

  STATUS              : ${PANEL_STATUS}
  LICENSE STATUS      : ${LICENSE_STATUS}
  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}

  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  DATA DIRECTORY      : ${DATA_DIR}
  CONFIGURATION       : ${ENV_FILE}
  SERVICE             : ${SERVICE_NAME}
  PROCESS MODE        : ${MODE}
  LOG FILE            : ${LOG_FILE}

──────────────────────────────────────────────────────────────

  SERVICE COMMANDS

    systemctl start ${SERVICE_NAME}
    systemctl stop ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f

  STANDALONE LOGS

    tail -f ${LOG_FILE}

──────────────────────────────────────────────────────────────

  LICENSE

    Current mode: ${LICENSE_MODE}
    License key is intentionally never displayed.

  Enable later with:

    LICENSE_MODE=required LICENSE_KEY=YOUR_KEY bash install.sh

──────────────────────────────────────────────────────────────

  SOURCE REPOSITORY

    ${REPO_URL}

  ZIP SOURCE

    ${ZIP_NAME}

╚════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
line
echo -e "${CYAN}HKVM installation finished.${NC}"
