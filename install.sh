#!/usr/bin/env bash
#
# VNM / HKVM Panel — production installer
#
# Default: direct access on port 8080.
# Optional: Cloudflare Tunnel + custom domain.
#
# Non-interactive example:
#   CLOUDFLARE_ENABLED=true \
#   CLOUDFLARE_DOMAIN=panel.example.com \
#   CLOUDFLARE_TUNNEL_TOKEN='...' \
#   bash install.sh
#
set -Eeuo pipefail

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
REPO_URL='https://github.com/stripathi02123-tech/Vnm-panel.git'
ZIP_NAME='Vnm-panel.zip'
INSTALL_DIR='/opt/hkvm'
APP_DIR="${INSTALL_DIR}/app"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
ENV_FILE="${INSTALL_DIR}/.env"
PID_FILE="${INSTALL_DIR}/hkvm.pid"
CREDENTIALS_FILE="${INSTALL_DIR}/admin-credentials.txt"
SERVICE_NAME='hkvm'
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CF_SERVICE_NAME='hkvm-cloudflared'
CF_SERVICE_FILE="/etc/systemd/system/${CF_SERVICE_NAME}.service"
CF_CONFIG_DIR='/etc/cloudflared'
CF_TOKEN_FILE="${CF_CONFIG_DIR}/hkvm-tunnel.token"
CF_LOG_FILE="${LOG_DIR}/cloudflared.log"
CF_PID_FILE="${INSTALL_DIR}/cloudflared.pid"
PORT="${PORT:-8080}"
CLOUDFLARE_ENABLED="${CLOUDFLARE_ENABLED:-}"
CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"

TMP_DIR=''; NODE_BIN=''; HAS_SYSTEMD='false'

info(){ printf '%b %s\n' "${CYAN}[INFO]${NC}" "$*"; }
ok(){ printf '%b %s\n' "${GREEN}[OK]${NC}" "$*"; }
warn(){ printf '%b %s\n' "${YELLOW}[WARN]${NC}" "$*"; }
die(){ printf '%b %s\n' "${RED}[ERROR]${NC}" "$*" >&2; exit 1; }
section(){ printf '\n%b\n' "${CYAN}==> $*${NC}"; }
cleanup(){ [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true; }
trap cleanup EXIT

require_root(){ [[ ${EUID} -eq 0 ]] || die 'Run this installer as root.'; }
require_os(){
  [[ -f /etc/os-release ]] || die '/etc/os-release is missing.'
  source /etc/os-release
  [[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || die "Ubuntu/Debian only (detected: ${ID:-unknown})."
}
detect_systemd(){
  local init
  init="$(ps -p 1 -o comm= 2>/dev/null || true)"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && [[ "${init}" == systemd ]]; then HAS_SYSTEMD='true'; fi
}
validate_port(){
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "Invalid PORT: ${PORT}"
  (( PORT >= 1024 && PORT <= 65535 )) || die 'PORT must be 1024-65535.'
}
normalize_domain(){
  CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN#http://}"
  CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN#https://}"
  CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN%%/*}"
  CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN%.}"
}
validate_domain(){
  normalize_domain
  [[ "${CLOUDFLARE_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid domain: ${CLOUDFLARE_DOMAIN}"
  [[ "${CLOUDFLARE_DOMAIN}" != *..* ]] || die 'Invalid domain: consecutive dots are not allowed.'
  (( ${#CLOUDFLARE_DOMAIN} <= 253 )) || die 'Domain is too long.'
}
configure_access(){
  if [[ -z "${CLOUDFLARE_ENABLED}" ]]; then
    if [[ -t 0 ]]; then
      printf '\nPanel access mode\n'
      printf '  1) Direct IP + port %s (default)\n' "${PORT}"
      printf '  2) Cloudflare Tunnel + custom domain\n\n'
      read -r -p 'Choose [1/2]: ' choice || true
      [[ "${choice:-1}" == 2 ]] && CLOUDFLARE_ENABLED='true' || CLOUDFLARE_ENABLED='false'
    else
      CLOUDFLARE_ENABLED='false'
    fi
  fi
  case "${CLOUDFLARE_ENABLED,,}" in
    1|y|yes|true|on) CLOUDFLARE_ENABLED='true' ;;
    0|n|no|false|off|'') CLOUDFLARE_ENABLED='false' ;;
    *) die 'CLOUDFLARE_ENABLED must be true or false.' ;;
  esac
  if [[ "${CLOUDFLARE_ENABLED}" == true ]]; then
    if [[ -z "${CLOUDFLARE_DOMAIN}" && -t 0 ]]; then read -r -p 'Cloudflare hostname (example: panel.example.com): ' CLOUDFLARE_DOMAIN; fi
    if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN}" && -t 0 ]]; then read -r -s -p 'Cloudflare Tunnel token: ' CLOUDFLARE_TUNNEL_TOKEN; printf '\n'; fi
    validate_domain
    [[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]] || die 'Cloudflare Tunnel token is required.'
  fi
}
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  section 'Installing system dependencies'
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git unzip file lsof procps iproute2 openssl build-essential python3 sqlite3 libsqlite3-dev rsync qemu-system-x86 qemu-utils ovmf cloud-init bridge-utils net-tools
}
install_cloudflared(){
  [[ "${CLOUDFLARE_ENABLED}" == true ]] || return 0
  command -v cloudflared >/dev/null 2>&1 && { ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -n1)"; return 0; }
  section 'Installing cloudflared'
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg > /usr/share/keyrings/cloudflare-main.gpg
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
}
detect_node(){
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
    [[ "${major}" =~ ^[0-9]+$ ]] && (( major >= 20 )) && NODE_BIN="$(command -v node)"
  fi
  if [[ -z "${NODE_BIN}" ]]; then
    section 'Installing Node.js 22'
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    NODE_BIN="$(command -v node)"
  fi
  command -v npm >/dev/null 2>&1 || die 'npm was not installed.'
  ok "Node.js $(node -v), npm $(npm -v)"
}
clone_extract(){
  TMP_DIR="$(mktemp -d -t vnm-installer-XXXXXX)"
  local repo="${TMP_DIR}/repo" extract="${TMP_DIR}/extract"
  mkdir -p "${extract}"
  section 'Downloading VNM Panel'
  git clone --depth 1 --single-branch "${REPO_URL}" "${repo}"
  local zip="${repo}/${ZIP_NAME}"
  [[ -f "${zip}" ]] || zip="$(find "${repo}" -type f -name "${ZIP_NAME}" -not -path '*/.git/*' -print -quit 2>/dev/null || true)"
  [[ -f "${zip}" ]] || die "${ZIP_NAME} not found in repository."
  unzip -t "${zip}" >/dev/null || die "${ZIP_NAME} is invalid."
  unzip -q "${zip}" -d "${extract}"
  local app=''
  while IFS= read -r f; do
    local d="$(dirname "${f}")"
    if [[ -f "${d}/package.json" ]]; then app="${d}"; [[ "$(basename "${d}")" =~ ^[Hh][Kk][Vv][Mm]$ ]] && break; fi
  done < <(find "${extract}" -type f -name app.js -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort)
  [[ -n "${app}" ]] || die 'Could not locate Hkvm/app.js in the archive.'
  section "Installing application into ${APP_DIR}"
  mkdir -p "${APP_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  rsync -a --delete --exclude='node_modules' --exclude='.git' --exclude='.env' "${app}/" "${APP_DIR}/"
  touch "${LOG_DIR}/hkvm.log"
  ok 'Application files copied.'
}
write_env(){
  section 'Writing configuration'
  mkdir -p "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  [[ -f "${ENV_FILE}" ]] && cp -a "${ENV_FILE}" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak" || true
  local secret
  secret="$(openssl rand -hex 32)"
  cat > "${ENV_FILE}" <<EOF_ENV
NODE_ENV=production
PORT=${PORT}
VNM_DATA_DIR=${DATA_DIR}
PANEL_NAME=VNM
DEFAULT_LOGO_URL=/images/logo.png
SESSION_SECRET=${secret}
LICENSE_MODE=disabled
LICENSE_KEY=
CLOUDFLARE_ENABLED=${CLOUDFLARE_ENABLED}
CLOUDFLARE_DOMAIN=${CLOUDFLARE_DOMAIN}
EOF_ENV
  chmod 600 "${ENV_FILE}"
}
install_npm(){
  section 'Installing npm dependencies'
  cd "${APP_DIR}"
  if [[ -f package-lock.json ]]; then npm ci --omit=dev || npm install --omit=dev; else npm install --omit=dev; fi
  npm rebuild sqlite3 >/dev/null 2>&1 || true
  "${NODE_BIN}" --check "${APP_DIR}/app.js" || die 'app.js syntax check failed.'
}
create_services(){
  [[ "${HAS_SYSTEMD}" == true ]] || return 0
  section 'Creating systemd services'
  cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=VNM / HKVM Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${APP_DIR}/app.js
Restart=on-failure
RestartSec=3
KillMode=control-group
StandardOutput=append:${LOG_DIR}/hkvm.log
StandardError=append:${LOG_DIR}/hkvm.log

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemd-analyze verify "${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null

  if [[ "${CLOUDFLARE_ENABLED}" == true ]]; then
    install -d -m 0700 "${CF_CONFIG_DIR}"
    printf '%s\n' "${CLOUDFLARE_TUNNEL_TOKEN}" > "${CF_TOKEN_FILE}"
    chmod 600 "${CF_TOKEN_FILE}"
    cat > "${CF_SERVICE_FILE}" <<EOF_CF
[Unit]
Description=VNM / HKVM Cloudflare Tunnel
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=$(command -v cloudflared) tunnel --no-autoupdate run --token-file ${CF_TOKEN_FILE}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_CF
    systemd-analyze verify "${CF_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable "${CF_SERVICE_NAME}" >/dev/null
  fi
}
start_services(){
  section 'Starting services'
  if [[ "${HAS_SYSTEMD}" == true ]]; then
    systemctl restart "${SERVICE_NAME}"
    [[ "${CLOUDFLARE_ENABLED}" == true ]] && systemctl restart "${CF_SERVICE_NAME}"
  else
    nohup "${NODE_BIN}" "${APP_DIR}/app.js" >> "${LOG_DIR}/hkvm.log" 2>&1 & echo $! > "${PID_FILE}"
    if [[ "${CLOUDFLARE_ENABLED}" == true ]]; then
      nohup "$(command -v cloudflared)" tunnel --no-autoupdate run --token-file "${CF_TOKEN_FILE}" >> "${CF_LOG_FILE}" 2>&1 & echo $! > "${CF_PID_FILE}"
    fi
  fi
}
health(){
  section 'Running health checks'
  local code='000'
  for _ in {1..30}; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    [[ "${code}" =~ ^[1-4][0-9][0-9]$ ]] && break
    sleep 1
  done
  [[ "${code}" =~ ^[1-4][0-9][0-9]$ ]] || { tail -n 120 "${LOG_DIR}/hkvm.log" 2>/dev/null || true; die "Panel health check failed (HTTP ${code})."; }
  ok "Panel responds on port ${PORT} (HTTP ${code})."
  if [[ "${CLOUDFLARE_ENABLED}" == true ]]; then
    if [[ "${HAS_SYSTEMD}" == true ]]; then systemctl is-active --quiet "${CF_SERVICE_NAME}" || { journalctl -u "${CF_SERVICE_NAME}" --no-pager -n 40 || true; die 'Cloudflare Tunnel is not running.'; }; else kill -0 "$(cat "${CF_PID_FILE}")" >/dev/null 2>&1 || die 'Cloudflare Tunnel process is not running.'; fi
    ok "Cloudflare Tunnel is running for ${CLOUDFLARE_DOMAIN}."
  fi
}
extract_credentials(){
  local pw
  pw="$(grep -F 'Default admin created. username: admin  password:' "${LOG_DIR}/hkvm.log" 2>/dev/null | tail -n1 | sed -E 's/^.*password:[[:space:]]*([^[:space:]]+).*$/\1/' || true)"
  if [[ -n "${pw}" ]]; then
    cat > "${CREDENTIALS_FILE}" <<EOF_CRED
VNM / HKVM Panel
Username: admin
Password: ${pw}
EOF_CRED
    chmod 600 "${CREDENTIALS_FILE}"
    ok "Admin credentials saved to ${CREDENTIALS_FILE}"
  else
    warn "Admin password is already configured or not present in the current log."
  fi
}
final(){
  local ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\n%b\n' "${GREEN}============================================================${NC}"
  printf '%b\n' "${GREEN}VNM / HKVM PANEL INSTALLATION COMPLETE${NC}"
  printf '%s\n' '============================================================'
  printf '  Port        : %s\n' "${PORT}"
  if [[ "${CLOUDFLARE_ENABLED}" == true ]]; then
    printf '  Access URL  : https://%s\n' "${CLOUDFLARE_DOMAIN}"
    printf '  Tunnel      : ENABLED\n'
    printf '  Origin      : http://127.0.0.1:%s\n' "${PORT}"
    printf '  Tunnel token: %s\n' "${CF_TOKEN_FILE} (protected)"
    printf '\n  Cloudflare Zero Trust must route the public hostname\n'
    printf '  %s to http://127.0.0.1:%s.\n' "${CLOUDFLARE_DOMAIN}" "${PORT}"
  else
    printf '  Access URL  : http://%s:%s\n' "${ip:-SERVER_IP}" "${PORT}"
    printf '  Cloudflare  : DISABLED\n'
  fi
  printf '  Service     : systemctl {status|restart|stop} %s\n' "${SERVICE_NAME}"
  [[ "${CLOUDFLARE_ENABLED}" == true ]] && printf '  Tunnel      : systemctl status %s\n' "${CF_SERVICE_NAME}"
  printf '  Logs        : %s/hkvm.log\n' "${LOG_DIR}"
  printf '%s\n' '============================================================'
}
main(){
  require_root; require_os; detect_systemd; validate_port; configure_access
  install_packages; install_cloudflared; detect_node
  clone_extract; write_env; install_npm; create_services; start_services; health; extract_credentials; final
}
main "$@"
