#!/usr/bin/env bash

# ============================================================
# HKVM PANEL V3 — ULTRA INSTALLER
# GitHub ZIP based installer
#
# Flow:
# GitHub repo
#   -> clone repo
#   -> find Vnm-panel.zip
#   -> extract ZIP
#   -> detect real Node.js application
#   -> install dependencies
#   -> configure .env + license
#   -> create systemd service OR standalone mode
#   -> start HKVM
# ============================================================

set -Eeuo pipefail

# ============================================================
# COLORS
# ============================================================

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
BLUE='\e[1;34m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
WHITE='\e[1;37m'
NC='\e[0m'

# ============================================================
# CONFIG
# ============================================================

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

PANEL_PORT="8080"
PANEL_NAME="HKVM"
NODE_MIN_MAJOR="20"

TMP_DIR=""
HAS_SYSTEMD="false"

# ============================================================
# HELPERS
# ============================================================

line() {
    echo -e "${MAGENTA}============================================================${NC}"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

die() {
    error "$*"
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}" || true
    fi
}

trap cleanup EXIT

# ============================================================
# ERROR HANDLER
# ============================================================

on_error() {
    local code=$?
    error "Installer failed at line ${BASH_LINENO[0]} (exit code ${code})."
    exit "${code}"
}

trap on_error ERR

# ============================================================
# LOGO
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
          ULTRA INSTALLER

EOF

echo -e "${NC}"
line

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "Please run this installer as root."
fi

ok "Root access detected."

# ============================================================
# OS DETECTION
# ============================================================

[[ -f /etc/os-release ]] || die "Unable to detect operating system."

# shellcheck disable=SC1091
source /etc/os-release

DISTRO="${ID:-unknown}"
VERSION="${VERSION_ID:-unknown}"
ARCH="$(uname -m)"
KERNEL="$(uname -r)"

info "Operating System : ${PRETTY_NAME:-${DISTRO} ${VERSION}}"
info "Architecture     : ${ARCH}"
info "Kernel           : ${KERNEL}"

case "${DISTRO}" in
    ubuntu|debian)
        ;;
    *)
        warn "This installer is designed for Debian/Ubuntu."
        read -r -p "Continue anyway? [y/N]: " CONTINUE_OS
        [[ "${CONTINUE_OS}" =~ ^[Yy]$ ]] || die "Installation cancelled."
        ;;
esac

line

# ============================================================
# SYSTEMD DETECTION
# ============================================================

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD="true"
    ok "systemd detected — service mode enabled."
else
    HAS_SYSTEMD="false"
    warn "systemd not detected — standalone/background mode enabled."
    info "This is expected in GitHub Codespaces and many containers."
fi

line

# ============================================================
# DEPENDENCIES
# ============================================================

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
    info "Updating package lists..."
    apt-get update -y

    info "Installing required packages..."
    apt-get install -y \
        ca-certificates \
        curl \
        git \
        unzip \
        file \
        lsof \
        procps \
        iproute2 \
        sudo \
        openssl \
        build-essential \
        python3
else
    die "APT package manager is required."
fi

ok "Base dependencies installed."

line

# ============================================================
# NODE.JS
# ============================================================

NODE_OK="false"

if command -v node >/dev/null 2>&1; then
    NODE_VERSION="$(node -v | sed 's/^v//')"
    NODE_MAJOR="${NODE_VERSION%%.*}"

    info "Detected Node.js: v${NODE_VERSION}"

    if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] &&
       (( NODE_MAJOR >= NODE_MIN_MAJOR )); then
        NODE_OK="true"
        ok "Node.js version is supported."
    else
        warn "Node.js ${NODE_VERSION} is too old."
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

# ============================================================
# DIRECTORIES
# ============================================================

info "Preparing HKVM directories..."

mkdir -p \
    "${INSTALL_DIR}" \
    "${DATA_DIR}" \
    "${LOG_DIR}" \
    "${BACKUP_DIR}" \
    "${ETC_DIR}"

chmod 755 "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${BACKUP_DIR}" "${ETC_DIR}"

touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

ok "HKVM directories prepared."

# ============================================================
# BACKUP EXISTING CONFIG
# ============================================================

if [[ -f "${ENV_FILE}" ]]; then
    BACKUP_ENV="${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${ENV_FILE}" "${BACKUP_ENV}"
    ok "Existing configuration backed up."
fi

# ============================================================
# STOP EXISTING INSTALLATION
# ============================================================

if [[ "${HAS_SYSTEMD}" == "true" ]] &&
   systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
    info "Stopping existing HKVM service..."
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "Existing service stopped."
fi

if [[ -f "${PID_FILE}" ]]; then
    OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"

    if [[ "${OLD_PID}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${OLD_PID}" >/dev/null 2>&1; then
            info "Stopping previous HKVM process (PID ${OLD_PID})..."
            kill "${OLD_PID}" >/dev/null 2>&1 || true

            for _ in {1..20}; do
                kill -0 "${OLD_PID}" >/dev/null 2>&1 || break
                sleep 0.2
            done

            kill -9 "${OLD_PID}" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "${PID_FILE}"
fi

# Also catch an orphaned previous process from a failed installer.
while read -r ORPHAN_PID; do
    [[ -z "${ORPHAN_PID}" ]] && continue
    kill "${ORPHAN_PID}" >/dev/null 2>&1 || true
done < <(pgrep -f '^node /opt/hkvm/app/app\.js$' 2>/dev/null || true)

line

# ============================================================
# TEMP DIRECTORY
# ============================================================

TMP_DIR="$(mktemp -d -t hkvm-installer-XXXXXX)"
REPO_DIR="${TMP_DIR}/repo"
EXTRACT_DIR="${TMP_DIR}/extracted"

mkdir -p "${EXTRACT_DIR}"

# ============================================================
# GITHUB CLONE
# ============================================================

info "Cloning HKVM repository..."

git clone \
    --depth 1 \
    --single-branch \
    "${REPO_URL}" \
    "${REPO_DIR}"

ok "Repository cloned."

# ============================================================
# FIND ZIP
# ============================================================

info "Searching for ${ZIP_NAME}..."

ZIP_FILE="${REPO_DIR}/${ZIP_NAME}"

if [[ ! -f "${ZIP_FILE}" ]]; then
    ZIP_FILE="$(find "${REPO_DIR}" -type f -name "${ZIP_NAME}" -print -quit 2>/dev/null || true)"
fi

[[ -n "${ZIP_FILE}" && -f "${ZIP_FILE}" ]] ||
    die "${ZIP_NAME} was not found inside the GitHub repository."

ZIP_SIZE_MB="$(du -m "${ZIP_FILE}" | awk '{print $1}')"

info "Found ${ZIP_NAME} (${ZIP_SIZE_MB} MB)."

(( ZIP_SIZE_MB >= 1 )) || die "ZIP file is empty or invalid."

ok "ZIP validation passed."

line

# ============================================================
# EXTRACT ZIP
# ============================================================

info "Extracting ${ZIP_NAME}..."

unzip -q "${ZIP_FILE}" -d "${EXTRACT_DIR}"

ok "ZIP extracted."

# ============================================================
# APPLICATION DETECTION
# ============================================================

info "Detecting HKVM Node.js application..."

# NEVER select package.json from node_modules.
mapfile -t PACKAGE_FILES < <(
    find "${EXTRACT_DIR}" \
        -type f \
        -name package.json \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -print | sort
)

[[ "${#PACKAGE_FILES[@]}" -gt 0 ]] ||
    die "No package.json found outside node_modules."

SOURCE_APP_DIR=""
PACKAGE_JSON=""

# First preference: package.json with a real start script or main entry.
for CANDIDATE in "${PACKAGE_FILES[@]}"; do
    CANDIDATE_DIR="$(dirname "${CANDIDATE}")"

    [[ "${CANDIDATE_DIR}" == *"/node_modules/"* ]] && continue

    if node -e '
const p=require(process.argv[1]);
const start = p.scripts && typeof p.scripts.start === "string" && p.scripts.start.trim();
const main = typeof p.main === "string" && p.main.trim();
process.exit(start || main ? 0 : 1);
' "${CANDIDATE}" >/dev/null 2>&1; then
        PACKAGE_JSON="${CANDIDATE}"
        SOURCE_APP_DIR="${CANDIDATE_DIR}"
        break
    fi
done

# Second preference: actual source directory containing common entry files.
if [[ -z "${SOURCE_APP_DIR}" ]]; then
    mapfile -t ENTRY_FILES < <(
        find "${EXTRACT_DIR}" \
            -type f \
            \( -name app.js -o -name server.js -o -name index.js -o -name main.js \) \
            -not -path '*/node_modules/*' \
            -not -path '*/.git/*' \
            -print | sort
    )

    for ENTRY in "${ENTRY_FILES[@]}"; do
        ENTRY_DIR="$(dirname "${ENTRY}")"
        [[ "${ENTRY_DIR}" == *"/node_modules/"* ]] && continue

        SOURCE_APP_DIR="${ENTRY_DIR}"
        break
    done
fi

[[ -n "${SOURCE_APP_DIR}" ]] ||
    die "Unable to locate the real HKVM application source in ${ZIP_NAME}."

[[ "${SOURCE_APP_DIR}" != *"/node_modules/"* ]] ||
    die "Safety check failed: application directory is inside node_modules."

info "Detected application directory: ${SOURCE_APP_DIR}"

# ============================================================
# INSTALL APPLICATION
# ============================================================

info "Installing application into ${APP_DIR}..."

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"

cp -a "${SOURCE_APP_DIR}/." "${APP_DIR}/"

ok "Application installed into ${APP_DIR}."

line

# ============================================================
# NPM DEPENDENCIES
# ============================================================

cd "${APP_DIR}"

[[ -f package.json ]] || die "Detected application directory has no package.json."

info "Installing Node.js dependencies..."

if [[ -f package-lock.json ]]; then
    if ! npm ci --omit=dev; then
        warn "npm ci failed; retrying with npm install..."
        npm install --omit=dev
    fi
else
    npm install --omit=dev
fi

ok "Node.js dependencies installed."

line

# ============================================================
# LICENSE CONFIGURATION
# ============================================================

echo
echo -e "${CYAN}HKVM LICENSE CONFIGURATION${NC}"
echo

LICENSE_MODE="required"
LICENSE_KEY=""

if [[ -f "${ENV_FILE}" ]]; then
    EXISTING_MODE="$(grep '^LICENSE_MODE=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    EXISTING_KEY="$(grep '^LICENSE_KEY=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"

    [[ -n "${EXISTING_MODE}" ]] && LICENSE_MODE="${EXISTING_MODE}"
    [[ -n "${EXISTING_KEY}" ]] && LICENSE_KEY="${EXISTING_KEY}"
fi

if [[ "${LICENSE_MODE}" == "disabled" ]]; then
    read -r -p "Keep LICENSE_MODE=disabled for development? [Y/n]: " KEEP_DISABLED

    if [[ ! "${KEEP_DISABLED}" =~ ^[Yy]?$ ]]; then
        LICENSE_MODE="required"
        LICENSE_KEY=""
    fi
fi

if [[ "${LICENSE_MODE}" != "disabled" ]]; then
    if [[ -z "${LICENSE_KEY}" ]]; then
        read -r -s -p "Enter HKVM license key: " LICENSE_KEY
        echo
    fi

    if [[ -z "${LICENSE_KEY}" ]]; then
        warn "No license key supplied."
        read -r -p "Use LICENSE_MODE=disabled for development? [y/N]: " DISABLE_LICENSE

        if [[ "${DISABLE_LICENSE}" =~ ^[Yy]$ ]]; then
            LICENSE_MODE="disabled"
        else
            die "A license key is required for production installation."
        fi
    else
        LICENSE_MODE="required"
        ok "License configuration received."
    fi
else
    warn "License mode disabled for development."
fi

# ============================================================
# SESSION SECRET
# ============================================================

info "Generating secure session secret..."

SESSION_SECRET="$(openssl rand -hex 32)"
[[ -n "${SESSION_SECRET}" ]] || die "Failed to generate SESSION_SECRET."

ok "Session secret generated."

# ============================================================
# CONFIGURATION
# ============================================================

info "Writing secure HKVM configuration..."

# Shell-escape values so the env file can be safely sourced in standalone mode.
printf -v Q_NODE_ENV '%q' "production"
printf -v Q_PORT '%q' "${PANEL_PORT}"
printf -v Q_PANEL_NAME '%q' "${PANEL_NAME}"
printf -v Q_DATA_DIR '%q' "${DATA_DIR}"
printf -v Q_SESSION_SECRET '%q' "${SESSION_SECRET}"
printf -v Q_LICENSE_MODE '%q' "${LICENSE_MODE}"
printf -v Q_LICENSE_KEY '%q' "${LICENSE_KEY}"
printf -v Q_INSTALL_DIR '%q' "${INSTALL_DIR}"
printf -v Q_APP_DIR '%q' "${APP_DIR}"
printf -v Q_LOG_DIR '%q' "${LOG_DIR}"

cat > "${ENV_FILE}" <<EOF
# HKVM Panel Configuration
NODE_ENV=${Q_NODE_ENV}
PORT=${Q_PORT}
PANEL_NAME=${Q_PANEL_NAME}
HKVM_DATA_DIR=${Q_DATA_DIR}
SESSION_SECRET=${Q_SESSION_SECRET}
LICENSE_MODE=${Q_LICENSE_MODE}
LICENSE_KEY=${Q_LICENSE_KEY}
HKVM_INSTALL_DIR=${Q_INSTALL_DIR}
HKVM_APP_DIR=${Q_APP_DIR}
HKVM_LOG_DIR=${Q_LOG_DIR}
EOF

chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}"

rm -f "${APP_DIR}/.env"
ln -s "${ENV_FILE}" "${APP_DIR}/.env"

ok "Secure HKVM configuration created."

line

# ============================================================
# START COMMAND DETECTION
# ============================================================

info "Detecting application start command..."

START_SCRIPT="$(node -e '
const p=require("./package.json");
process.stdout.write((p.scripts && p.scripts.start) || "");
' 2>/dev/null || true)"

MAIN_FILE="$(node -e '
const p=require("./package.json");
process.stdout.write((p.main) || "");
' 2>/dev/null || true)"

EXEC_KIND=""
EXEC_ARG=""

if [[ -n "${START_SCRIPT}" ]]; then
    EXEC_KIND="npm"
    info "Using npm start."
elif [[ -n "${MAIN_FILE}" && -f "${APP_DIR}/${MAIN_FILE}" ]]; then
    EXEC_KIND="node"
    EXEC_ARG="${MAIN_FILE}"
    info "Using package.json main: ${MAIN_FILE}"
else
    ENTRY_FILE=""

    for CANDIDATE in app.js server.js index.js main.js; do
        if [[ -f "${APP_DIR}/${CANDIDATE}" ]]; then
            ENTRY_FILE="${CANDIDATE}"
            break
        fi
    done

    if [[ -z "${ENTRY_FILE}" ]]; then
        ENTRY_FILE="$(find "${APP_DIR}" -maxdepth 2 -type f \
            \( -name app.js -o -name server.js -o -name index.js -o -name main.js \) \
            -not -path '*/node_modules/*' \
            -print -quit 2>/dev/null || true)"

        if [[ -n "${ENTRY_FILE}" ]]; then
            ENTRY_FILE="${ENTRY_FILE#${APP_DIR}/}"
        fi
    fi

    [[ -n "${ENTRY_FILE}" ]] || die "Unable to detect application entrypoint."

    EXEC_KIND="node"
    EXEC_ARG="${ENTRY_FILE}"
    info "Using Node entrypoint: ${ENTRY_FILE}"
fi

# ============================================================
# FIREWALL
# ============================================================

info "Checking firewall..."

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    ok "UFW rule checked."
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld rule checked."
else
    info "No supported firewall manager detected."
fi

line

# ============================================================
# SYSTEMD MODE
# ============================================================

if [[ "${HAS_SYSTEMD}" == "true" ]]; then

    info "Creating systemd service..."

    if [[ "${EXEC_KIND}" == "npm" ]]; then
        EXEC_LINE="$(command -v npm) start"
    else
        EXEC_LINE="$(command -v node) ${APP_DIR}/${EXEC_ARG}"
    fi

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HKVM Panel V3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_LINE}
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

    info "Starting HKVM service..."
    systemctl restart "${SERVICE_NAME}"

    sleep 5

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "HKVM service is ONLINE."
    else
        error "HKVM service failed to start."
        systemctl status "${SERVICE_NAME}" --no-pager --full || true
        echo
        journalctl -u "${SERVICE_NAME}" -n 120 --no-pager || true
        exit 1
    fi

else

    # ========================================================
    # STANDALONE MODE (CODESPACES / CONTAINERS)
    # ========================================================

    info "Starting HKVM in standalone/background mode..."

    cd "${APP_DIR}"
    : > "${LOG_FILE}"

    if [[ "${EXEC_KIND}" == "npm" ]]; then
        nohup bash -c 'set -a; source "$1"; set +a; exec npm start' _ "${ENV_FILE}" \
            >>"${LOG_FILE}" 2>&1 &
    else
        nohup bash -c 'set -a; source "$1"; set +a; exec node "$2"' _ "${ENV_FILE}" "${APP_DIR}/${EXEC_ARG}" \
            >>"${LOG_FILE}" 2>&1 &
    fi

    HKVM_PID=$!
    echo "${HKVM_PID}" > "${PID_FILE}"

    sleep 5

    if kill -0 "${HKVM_PID}" >/dev/null 2>&1; then
        ok "HKVM process is running (PID ${HKVM_PID})."
    else
        error "HKVM process exited during startup."
        echo
        echo "---------------- HKVM STARTUP LOG ----------------"
        tail -n 160 "${LOG_FILE}" || true
        echo "---------------------------------------------------"
        echo
        die "HKVM failed to start. The startup log above contains the real error."
    fi
fi

line

# ============================================================
# PORT HEALTH CHECK
# ============================================================

info "Checking panel port ${PANEL_PORT}..."

PANEL_STATUS="OFFLINE"

for _ in {1..15}; do
    if ss -ltn 2>/dev/null | grep -q ":${PANEL_PORT}\\b"; then
        PANEL_STATUS="ONLINE"
        break
    fi
    sleep 1
done

if [[ "${PANEL_STATUS}" == "ONLINE" ]]; then
    ok "Port ${PANEL_PORT} is listening."
else
    warn "Port ${PANEL_PORT} is not listening."
fi

# ============================================================
# HTTP HEALTH CHECK
# ============================================================

HTTP_STATUS="000"

HTTP_STATUS="$(
    curl \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 8 \
        "http://127.0.0.1:${PANEL_PORT}/" \
        2>/dev/null || true
)"

if [[ "${HTTP_STATUS}" =~ ^[0-9]{3}$ ]] && [[ "${HTTP_STATUS}" != "000" ]]; then
    ok "HTTP health check passed (${HTTP_STATUS})."
else
    warn "HTTP health check did not return a normal response."
fi

line

# ============================================================
# PUBLIC IP
# ============================================================

info "Detecting server IP..."

PUBLIC_IP=""

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="YOUR_SERVER_IP"
fi

# ============================================================
# LICENSE STATUS
# ============================================================

if [[ "${LICENSE_MODE}" == "required" && -n "${LICENSE_KEY}" ]]; then
    LICENSE_STATUS="CONFIGURED"
elif [[ "${LICENSE_MODE}" == "disabled" ]]; then
    LICENSE_STATUS="DISABLED"
else
    LICENSE_STATUS="NOT CONFIGURED"
fi

# ============================================================
# PROCESS STATUS
# ============================================================

HKVM_PROCESS="NOT RUNNING"

if [[ "${HAS_SYSTEMD}" == "true" ]]; then
    systemctl is-active --quiet "${SERVICE_NAME}" && HKVM_PROCESS="RUNNING"
elif [[ -f "${PID_FILE}" ]]; then
    CURRENT_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ "${CURRENT_PID}" =~ ^[0-9]+$ ]] && kill -0 "${CURRENT_PID}" >/dev/null 2>&1; then
        HKVM_PROCESS="RUNNING"
    fi
fi

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

  LICENSE STATUS      : ${LICENSE_STATUS}

  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}

  INSTALL DIRECTORY   : ${INSTALL_DIR}

  APPLICATION         : ${APP_DIR}

  DATA DIRECTORY      : ${DATA_DIR}

  CONFIGURATION       : ${ENV_FILE}

  SERVICE             : ${SERVICE_NAME}

  PROCESS             : ${HKVM_PROCESS}

  LOG FILE            : ${LOG_FILE}

  MODE                : $([[ "${HAS_SYSTEMD}" == "true" ]] && echo SYSTEMD || echo STANDALONE)

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

──────────────────────────────────────────────────────────────

  LIVE LOGS

    journalctl -u ${SERVICE_NAME} -f

  OR

    tail -f ${LOG_FILE}

──────────────────────────────────────────────────────────────

  STANDALONE / CODESPACES

    PID:
      ${PID_FILE}

    Logs:
      ${LOG_FILE}

──────────────────────────────────────────────────────────────

  SOURCE REPOSITORY

    ${REPO_URL}

  ZIP SOURCE

    ${ZIP_NAME}

──────────────────────────────────────────────────────────────

  LICENSE

    Mode:
      ${LICENSE_MODE}

    The actual license key is intentionally not displayed.

╚════════════════════════════════════════════════════════════╝

EOF

echo -e "${NC}"

if [[ "${PANEL_STATUS}" == "ONLINE" ]]; then
    ok "HKVM Panel is running on port ${PANEL_PORT}."
else
    warn "HKVM was installed but the panel is not listening."

    if [[ "${HAS_SYSTEMD}" == "true" ]]; then
        warn "Check: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
    else
        warn "Check: tail -n 160 ${LOG_FILE}"
    fi
fi

line

echo -e "${CYAN}HKVM installation finished.${NC}"
