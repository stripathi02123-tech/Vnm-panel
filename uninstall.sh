#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM / HKVM PANEL — SAFE UNINSTALLER
# Default: remove application/service/config, preserve persistent data.
# Full purge: sudo bash uninstall.sh --purge
# ============================================================================

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[1;36m'
readonly MAGENTA='\033[1;35m'
readonly NC='\033[0m'

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
readonly DEFAULT_DB_DIR='/root/.vnm'
readonly DEFAULT_VM_DIR='/root/vms'

PURGE='false'

line(){ printf '%b\n' "${MAGENTA}============================================================${NC}"; }
info(){ printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARNING]${NC} $*"; }
error(){ printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
die(){ error "$*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die 'Run this uninstaller as root.'

case "${1:-}" in
    '') PURGE='false' ;;
    --purge) PURGE='true' ;;
    -h|--help)
        echo 'Usage: sudo bash uninstall.sh [--purge]'
        echo 'Default: preserve persistent VM/database data.'
        echo '--purge: delete known persistent HKVM data after confirmation.'
        exit 0
        ;;
    *) die "Unknown argument: $1" ;;
esac

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
               UNINSTALLER

EOF
printf '%b\n' "${NC}"
line

if [[ ! -d "${INSTALL_DIR}" && ! -f "${SERVICE_FILE}" ]]; then
    warn 'HKVM does not appear to be installed.'
    exit 0
fi

if [[ "${PURGE}" == 'true' ]]; then
    warn 'PURGE MODE will delete persistent HKVM data.'
    echo
    echo "The following known paths will be removed if present:"
    echo "  ${DATA_DIR}"
    echo "  ${BACKUP_DIR}"
    echo "  ${DEFAULT_DB_DIR}"
    echo "  ${DEFAULT_VM_DIR}"
    echo "  ${INSTALL_DIR}"
    echo
    read -r -p 'Type DELETE to continue: ' confirmation
    [[ "${confirmation}" == 'DELETE' ]] || die 'Purge cancelled.'
fi

line
info 'Stopping HKVM...'

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

if [[ -f "${PID_FILE}" ]]; then
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" >/dev/null 2>&1; then
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

while read -r pid; do
    [[ -z "${pid}" ]] && continue
    cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    if [[ "${cwd}" == "${APP_DIR}" || "${cmd}" == *"${APP_DIR}/app.js"* ]]; then
        kill "${pid}" >/dev/null 2>&1 || true
    fi
done < <(pgrep -f '/opt/hkvm/app/app\.js' 2>/dev/null || true)

ok 'HKVM processes stopped.'

line
info 'Removing service and application files...'

rm -f "${SERVICE_FILE}"
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

rm -rf "${APP_DIR}"
rm -f "${ENV_FILE}" "${CREDENTIALS_FILE}" "${PID_FILE}"
rm -f "${LOG_DIR}/hkvm.log"

if [[ "${PURGE}" == 'true' ]]; then
    info 'Removing persistent HKVM data...'
    rm -rf "${DATA_DIR}" "${BACKUP_DIR}"
    rm -rf "${DEFAULT_DB_DIR}" "${DEFAULT_VM_DIR}"
    rm -rf "${INSTALL_DIR}"
    ok 'Persistent data removed.'
else
    ok 'Application and configuration removed.'
    warn 'Persistent data was preserved:'
    echo "  ${DATA_DIR}"
    echo "  ${BACKUP_DIR}"
    echo "  ${DEFAULT_DB_DIR}"
    echo "  ${DEFAULT_VM_DIR}"
fi

line
info 'Verifying port 8080 cleanup...'

if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -t -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
        for pid in ${pids}; do
            cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
            cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
            if [[ "${cwd}" == "${APP_DIR}" || "${cmd}" == *"${APP_DIR}/app.js"* ]]; then
                die "HKVM is still listening on port 8080 (PID ${pid})."
            fi
        done
        warn 'Port 8080 is still used by another application; it was left untouched.'
    else
        ok 'HKVM is no longer listening on port 8080.'
    fi
fi

line
if [[ "${PURGE}" == 'true' ]]; then
    ok 'HKVM has been completely removed.'
else
    ok 'HKVM application has been uninstalled.'
    info 'Persistent VM/database data remains available for a future reinstall.'
    info 'Use: sudo bash uninstall.sh --purge  to remove the preserved data.'
fi
