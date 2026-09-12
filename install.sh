#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM / HKVM PANEL — PRODUCTION INSTALLER
# GitHub repository -> Vnm-panel.zip -> Hkvm/app.js -> install -> run
# Development build: licensing disabled, no license prompt.
# ============================================================================

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[1;36m'
readonly MAGENTA='\033[1;35m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

readonly REPO_URL='https://github.com/stripathi02123-tech/Vnm-panel.git'
readonly ZIP_NAME='Vnm-panel.zip'
readonly INSTALL_DIR='/opt/hkvm'
readonly APP_DIR="${INSTALL_DIR}/app"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly BACKUP_DIR="${INSTALL_DIR}/backups"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly PID_FILE="${INSTALL_DIR}/hkvm.pid"
readonly CREDENTIALS_FILE="${INSTALL_DIR}/admin-credentials.txt"
readonly SERVICE_NAME='hkvm'
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly PORT="${PORT:-8080}"

TMP_DIR=''
NODE_BIN=''
NPM_BIN=''
APP_JS=''
HAS_SYSTEMD='false'

line(){ printf '%b\n' "${MAGENTA}============================================================${NC}"; }
info(){ printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARNING]${NC} $*"; }
error(){ printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
die(){ error "$*"; exit 1; }

cleanup(){
    local rc=$?
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true
    if (( rc != 0 )); then
        error "Installation failed (exit ${rc})."
        if [[ -f "${LOG_DIR}/hkvm.log" ]]; then
            echo '---------------- HKVM LOG ----------------' >&2
            tail -n 180 "${LOG_DIR}/hkvm.log" >&2 || true
            echo '-------------------------------------------' >&2
        fi
    fi
}
trap cleanup EXIT

print_logo(){
    clear 2>/dev/null || true
    printf '%b\n' "${CYAN}"
    cat <<'EOF'

██╗  ██╗██╗  ██╗██╗   ██╗███╗   ███╗
██║ ██╔╝██║ ██╔╝██║   ██║████╗ ████║
█████╔╝ █████╔╝ ██║   ██║██╔████╔██║
██╔═██╗ ██╔═██╗ ╚██╗ ██╔╝██║╚██╔╝██║
██║  ██╗██║  ██╗ ╚████╔╝ ██║ ╚═╝ ██║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝

             HKVM PANEL V3
          PRODUCTION INSTALLER

EOF
    printf '%b\n' "${NC}"
    line
}

check_os(){
    [[ ${EUID} -eq 0 ]] || die 'Run this installer as root.'
    [[ -f /etc/os-release ]] || die 'Cannot detect operating system.'
    # shellcheck disable=SC1091
    source /etc/os-release

    info "Operating System : ${PRETTY_NAME:-unknown}"
    info "Architecture     : $(uname -m)"
    info "Kernel           : $(uname -r)"

    [[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] ||
        die "Unsupported OS: ${ID:-unknown}. Ubuntu/Debian only."

    local init_name
    init_name="$(ps -p 1 -o comm= 2>/dev/null || true)"
    if command -v systemctl >/dev/null 2>&1 &&
       [[ -d /run/systemd/system ]] &&
       [[ "${init_name}" == 'systemd' ]]; then
        HAS_SYSTEMD='true'
        ok 'systemd detected — service mode enabled.'
    else
        HAS_SYSTEMD='false'
        warn 'systemd not detected — standalone/background mode enabled.'
        info 'This is normal in GitHub Codespaces and containers.'
    fi
}

install_packages(){
    export DEBIAN_FRONTEND=noninteractive
    info 'Updating package lists...'
    apt-get update -y

    info 'Installing base dependencies...'
    apt-get install -y \
        ca-certificates curl git unzip file lsof procps iproute2 \
        openssl build-essential python3 sqlite3 libsqlite3-dev rsync

    if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
        info 'Installing virtualization dependencies...'
        apt-get install -y \
            qemu-system-x86 qemu-utils ovmf cloud-init \
            libvirt-daemon-system libvirt-clients
    else
        warn 'Skipping libvirt/QEMU host stack in container mode.'
    fi
    ok 'System dependencies installed.'
    line
}

detect_node(){
    if command -v node >/dev/null 2>&1; then
        local v major
        v="$(node -v | sed 's/^v//')"
        major="${v%%.*}"
        NODE_BIN="$(command -v node)"
        if [[ "${major}" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
            ok "Node.js detected: v${v}"
        else
            NODE_BIN=''
        fi
    fi

    if [[ -z "${NODE_BIN}" ]]; then
        info 'Installing Node.js 22...'
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
    fi

    NODE_BIN="$(command -v node)"
    NPM_BIN="$(command -v npm || true)"
    [[ -x "${NODE_BIN}" ]] || die "Node binary is not executable: ${NODE_BIN}"
    [[ -x "${NPM_BIN}" ]] || die 'npm was not found.'

    ok "Node.js: $(${NODE_BIN} -v) | npm: $(${NPM_BIN} -v)"
    info "Node binary: ${NODE_BIN}"
    line
}

stop_existing(){
    info 'Stopping any existing HKVM instance...'

    if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
        systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" >/dev/null 2>&1; then
            local cmd cwd
            cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
            cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
            if [[ "${cwd}" == "${APP_DIR}" || "${cmd}" == *"${APP_DIR}/app.js"* ]]; then
                kill "${pid}" >/dev/null 2>&1 || true
                for _ in {1..20}; do
                    kill -0 "${pid}" >/dev/null 2>&1 || break
                    sleep 0.2
                done
                kill -9 "${pid}" >/dev/null 2>&1 || true
            fi
        fi
        rm -f "${PID_FILE}"
    fi

    if command -v pgrep >/dev/null 2>&1; then
        while read -r pid; do
            [[ -z "${pid}" ]] && continue
            local cmd cwd
            cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
            cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
            if [[ "${cwd}" == "${APP_DIR}" || "${cmd}" == *"${APP_DIR}/app.js"* ]]; then
                kill "${pid}" >/dev/null 2>&1 || true
            fi
        done < <(pgrep -f '/opt/hkvm/app/app\.js' 2>/dev/null || true)
    fi

    if command -v lsof >/dev/null 2>&1; then
        mapfile -t pids < <(lsof -t -nP -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)
        for pid in "${pids[@]:-}"; do
            [[ "${pid}" =~ ^[0-9]+$ ]] || continue
            local cmd cwd
            cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
            cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
            if [[ "${cwd}" == "${APP_DIR}" || "${cmd}" == *"${APP_DIR}/app.js"* ]]; then
                kill "${pid}" >/dev/null 2>&1 || true
                sleep 1
                kill -9 "${pid}" >/dev/null 2>&1 || true
            else
                die "Port ${PORT} is already used by another process (PID ${pid})."
            fi
        done
    fi

    ok 'Existing HKVM instance stopped.'
    line
}

prepare_storage(){
    info "Preparing ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
    chmod 755 "${INSTALL_DIR}" "${APP_DIR}" 2>/dev/null || true
    chmod 755 "${DATA_DIR}" "${LOG_DIR}"
    chmod 700 "${BACKUP_DIR}"
    touch "${LOG_DIR}/hkvm.log"
    chmod 640 "${LOG_DIR}/hkvm.log"

    if [[ -f "${ENV_FILE}" ]]; then
        cp -a "${ENV_FILE}" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"
        ok 'Existing configuration backed up.'
    fi
    ok 'Storage prepared.'
    line
}

download_and_extract(){
    TMP_DIR="$(mktemp -d -t hkvm-installer-XXXXXX)"
    local repo_dir="${TMP_DIR}/repo"
    local extract_dir="${TMP_DIR}/extract"
    mkdir -p "${extract_dir}"

    info 'Cloning HKVM repository...'
    git clone --depth 1 --single-branch "${REPO_URL}" "${repo_dir}"
    ok 'Repository cloned.'

    local zip_file="${repo_dir}/${ZIP_NAME}"
    if [[ ! -f "${zip_file}" ]]; then
        zip_file="$(find "${repo_dir}" -type f -name "${ZIP_NAME}" -not -path '*/.git/*' -print -quit 2>/dev/null || true)"
    fi
    [[ -n "${zip_file}" && -f "${zip_file}" ]] || die "${ZIP_NAME} was not found in the repository."

    unzip -t "${zip_file}" >/dev/null || die "${ZIP_NAME} is corrupted or invalid."
    info "Found ${ZIP_NAME}: $(du -m "${zip_file}" | awk '{print $1}') MB"
    info 'Extracting application...'
    unzip -q "${zip_file}" -d "${extract_dir}"
    ok 'ZIP extracted.'
    line

    detect_app_root "${extract_dir}"
}

detect_app_root(){
    local extract_dir="$1"
    info 'Detecting real HKVM application root...'

    mapfile -t app_files < <(
        find "${extract_dir}" -type f -name app.js \
            -not -path '*/node_modules/*' -not -path '*/.git/*' \
            -print | sort
    )

    local source_dir=''
    if (( ${#app_files[@]} > 0 )); then
        for f in "${app_files[@]}"; do
            local d base
            d="$(dirname "${f}")"
            base="$(basename "${d}")"
            if [[ "${base}" =~ ^[Hh][Kk][Vv][Mm]$ ]] && [[ -f "${d}/package.json" ]]; then
                source_dir="${d}"
                break
            fi
        done
        [[ -n "${source_dir}" ]] || source_dir="$(dirname "${app_files[0]}")"
    fi

    [[ -n "${source_dir}" ]] || die 'Could not locate app.js outside node_modules.'
    [[ -f "${source_dir}/app.js" ]] || die 'Detected root is missing app.js.'
    [[ -f "${source_dir}/package.json" ]] || die 'Detected root is missing package.json.'
    [[ "${source_dir}" != *'/node_modules/'* ]] || die 'Safety failure: app root is inside node_modules.'

    info "Application root: ${source_dir}"
    rm -rf "${APP_DIR}"
    mkdir -p "${APP_DIR}"
    rsync -a --exclude='node_modules' --exclude='.git' "${source_dir}/" "${APP_DIR}/"

    [[ -f "${APP_DIR}/app.js" ]] || die 'app.js was not copied.'
    [[ -f "${APP_DIR}/package.json" ]] || die 'package.json was not copied.'
    ok "Application installed into ${APP_DIR}."
    line
}

install_npm(){
    cd "${APP_DIR}"
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
    "${NPM_BIN}" rebuild sqlite3 ssh2 >/dev/null 2>&1 || true

    for module in bcryptjs sqlite3 ssh2; do
        "${NODE_BIN}" -e "require('${module}'); process.stdout.write('ok')" >/dev/null 2>&1 ||
            die "Required Node module failed to load: ${module}"
        ok "Runtime module verified: ${module}"
    done
    line
}

write_env(){
    local session_secret
    session_secret="$(openssl rand -hex 32)"
    [[ -n "${session_secret}" ]] || die 'Failed to generate session secret.'

    cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${PORT}
VNM_DATA_DIR=${DATA_DIR}
PANEL_NAME=VNM
DEFAULT_LOGO_URL=/images/logo.png
SESSION_SECRET=${session_secret}
LICENSE_MODE=disabled
LICENSE_KEY=
EOF
    chmod 600 "${ENV_FILE}"
    ok 'Configuration created.'
    ok 'License is DISABLED — no key is required.'
    line
}

patch_login_csrf(){
    APP_JS="${APP_DIR}/app.js"
    info 'Checking login CSRF handling...'

    if ! grep -Eq 'function[[:space:]]+csrfProtection[[:space:]]*\(' "${APP_JS}"; then
        warn 'Named csrfProtection function was not found; source was not modified.'
        return 0
    fi

    cp -a "${APP_JS}" "${BACKUP_DIR}/app.js.csrf.$(date +%Y%m%d-%H%M%S).bak"

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
if not match:
    raise SystemExit(2)
src = src[:match.start()] + replacement + src[match.end():]
path.write_text(src, encoding='utf-8')
PY

    "${NODE_BIN}" --check "${APP_JS}" || die 'app.js syntax check failed after CSRF compatibility change.'
    ok 'Login CSRF compatibility check passed.'
    line
}

create_service(){
    [[ "${HAS_SYSTEMD}" == 'true' ]] || return 0

    info 'Creating systemd service...'
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VNM/HKVM Panel
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
RestartSec=5
KillMode=control-group
StandardOutput=append:${LOG_DIR}/hkvm.log
StandardError=append:${LOG_DIR}/hkvm.log

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${SERVICE_FILE}"
    systemd-analyze verify "${SERVICE_FILE}" || die 'systemd service validation failed.'
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    ok 'systemd service created and validated.'
    line
}

start_app(){
    : > "${LOG_DIR}/hkvm.log"

    if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
        info 'Starting HKVM with systemd...'
        systemctl restart "${SERVICE_NAME}"
    else
        info 'Starting HKVM in standalone/background mode...'
        cd "${APP_DIR}"
        nohup "${NODE_BIN}" "${APP_DIR}/app.js" >>"${LOG_DIR}/hkvm.log" 2>&1 &
        echo "$!" > "${PID_FILE}"
        chmod 600 "${PID_FILE}"
    fi
}

is_hkvm_process(){
    local pid="$1"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${pid}" >/dev/null 2>&1 || return 1
    local cmd cwd
    cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    [[ "${cmd}" == *"${APP_DIR}/app.js"* || "${cwd}" == "${APP_DIR}" ]]
}

health_check(){
    line
    info 'Performing startup health checks...'

    local pid=''
    local process_ok='false'
    for _ in {1..30}; do
        if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
            pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)"
        elif [[ -f "${PID_FILE}" ]]; then
            pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        fi
        if [[ -n "${pid}" ]] && is_hkvm_process "${pid}"; then
            process_ok='true'
            break
        fi
        sleep 1
    done

    if [[ "${process_ok}" != 'true' ]]; then
        error 'HKVM process did not remain running.'
        tail -n 180 "${LOG_DIR}/hkvm.log" || true
        return 1
    fi
    ok "HKVM process is running (PID: ${pid})."

    local listening='false'
    for _ in {1..15}; do
        if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
            listening='true'
            break
        fi
        sleep 1
    done
    [[ "${listening}" == 'true' ]] || {
        error "Port ${PORT} is not listening."
        tail -n 180 "${LOG_DIR}/hkvm.log" || true
        return 1
    }
    ok "Port ${PORT} is listening."

    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    if [[ "${code}" =~ ^[1-4][0-9][0-9]$ ]]; then
        ok "HTTP endpoint responding (${code})."
    else
        error "HTTP health check failed (HTTP ${code:-000})."
        tail -n 180 "${LOG_DIR}/hkvm.log" || true
        return 1
    fi
    line
}

verify_admin(){
    # Fresh installs: the app prints a generated password. Verify that password
    # against the actual bcrypt hash. If it does not match, repair the admin row.
    local db_file=''
    for candidate in /root/.vnm/vnm.db "${DATA_DIR}/vnm.db" "${APP_DIR}/data/vnm.db"; do
        if [[ -f "${candidate}" ]]; then
            db_file="${candidate}"
            break
        fi
    done

    [[ -n "${db_file}" ]] || { warn 'Admin database not found yet; leaving account setup to the application.'; return 0; }

    local generated
    generated="$(grep -F 'Default admin created. username: admin  password:' "${LOG_DIR}/hkvm.log" 2>/dev/null | tail -n1 | sed -E 's/^.*password:[[:space:]]*([^[:space:]]+).*$/\1/' || true)"

    if [[ -z "${generated}" ]]; then
        info 'Existing admin account detected; existing password preserved.'
        return 0
    fi

    local valid
    valid="$(DB_FILE="${db_file}" DEFAULT_PASSWORD="${generated}" "${NODE_BIN}" <<'NODE' 2>/dev/null || true
const bcrypt = require('/opt/hkvm/app/node_modules/bcryptjs');
const sqlite3 = require('/opt/hkvm/app/node_modules/sqlite3');
const db = new sqlite3.Database(process.env.DB_FILE);
db.get('SELECT password FROM users WHERE username = ?', ['admin'], (err,row) => {
  process.stdout.write(err || !row ? 'NO' : (bcrypt.compareSync(process.env.DEFAULT_PASSWORD, row.password) ? 'YES' : 'NO'));
  db.close();
});
NODE
    )"

    local final_password="${generated}"
    if [[ "${valid}" != 'YES' ]]; then
        warn 'Generated admin password did not match the stored hash; repairing the account.'
        final_password="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
        [[ "${#final_password}" -ge 12 ]] || final_password="$(openssl rand -hex 12)"
        local hash
        hash="$(REPAIR_PASSWORD="${final_password}" "${NODE_BIN}" -e "console.log(require('${APP_DIR}/node_modules/bcryptjs').hashSync(process.env.REPAIR_PASSWORD, 10))")"
        DB_FILE="${db_file}" REPAIRED_HASH="${hash}" "${NODE_BIN}" <<'NODE'
const sqlite3 = require('/opt/hkvm/app/node_modules/sqlite3');
const db = new sqlite3.Database(process.env.DB_FILE);
db.run('UPDATE users SET password = ?, role = ?, is_active = 1 WHERE username = ?', [process.env.REPAIRED_HASH, 'admin', 'admin'], function(err) {
  if (err || this.changes !== 1) process.exitCode = 1;
  db.close();
});
NODE
        ok 'Admin password repaired and verified.'
    else
        ok 'Generated admin password verified against the database.'
    fi

    cat > "${CREDENTIALS_FILE}" <<EOF
VNM/HKVM Panel
Username: admin
Password: ${final_password}
EOF
    chmod 600 "${CREDENTIALS_FILE}"
}

access_url(){
    if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
        printf 'https://%s-%s.%s' "${CODESPACE_NAME}" "${PORT}" "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    else
        printf 'http://%s:%s' "$(hostname -I 2>/dev/null | awk '{print $1}' || echo YOUR_SERVER_IP)" "${PORT}"
    fi
}

final_screen(){
    local url
    url="$(access_url)"
    clear 2>/dev/null || true
    printf '%b\n' "${GREEN}"
    cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                    HKVM PANEL V3                           ║
║              INSTALLATION COMPLETE                        ║
╚════════════════════════════════════════════════════════════╝

  STATUS              : ONLINE
  LICENSE STATUS      : DISABLED

  PANEL URL           : ${url}

  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  ENTRYPOINT          : ${APP_JS}
  DATA DIRECTORY      : ${DATA_DIR}
  CONFIGURATION       : ${ENV_FILE}

  SERVICE             : ${SERVICE_NAME}
  PROCESS             : RUNNING
  MODE                : $([[ "${HAS_SYSTEMD}" == 'true' ]] && echo SYSTEMD || echo STANDALONE)
  NODE BINARY         : ${NODE_BIN}
  LOG FILE            : ${LOG_DIR}/hkvm.log

──────────────────────────────────────────────────────────────

  ADMIN CREDENTIALS

    Username          : admin
    Credentials file  : ${CREDENTIALS_FILE}

    View with:
      cat ${CREDENTIALS_FILE}

──────────────────────────────────────────────────────────────

  SERVICE COMMANDS

    Start:
      systemctl start ${SERVICE_NAME}

    Stop:
      systemctl stop ${SERVICE_NAME}

    Restart:
      systemctl restart ${SERVICE_NAME}

    Status:
      systemctl status ${SERVICE_NAME}

    Logs:
      journalctl -u ${SERVICE_NAME} -f

  Standalone log:
      tail -f ${LOG_DIR}/hkvm.log

╚════════════════════════════════════════════════════════════╝

EOF
    printf '%b\n' "${NC}"
    if [[ "${HAS_SYSTEMD}" != 'true' ]]; then
        warn 'Standalone mode does not survive Codespace/container shutdowns.'
    fi
    ok 'HKVM installation finished successfully.'
}

main(){
    print_logo
    check_os
    install_packages
    detect_node
    stop_existing
    prepare_storage
    download_and_extract
    install_npm
    write_env
    patch_login_csrf
    create_service
    start_app
    health_check
    verify_admin
    final_screen
}

main "$@"
