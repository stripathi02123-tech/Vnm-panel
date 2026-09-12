#!/usr/bin/env bash
set -Eeuo pipefail

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; CYAN='\e[1;36m'; MAGENTA='\e[1;35m'; NC='\e[0m'
APP_NAME="HKVM"; SERVICE_NAME="hkvm"
REPO_URL="https://github.com/stripathi02123-tech/Vnm-panel.git"; ZIP_NAME="Vnm-panel.zip"
INSTALL_DIR="/opt/hkvm"; APP_DIR="${INSTALL_DIR}/app"; DATA_DIR="${INSTALL_DIR}/data"; LOG_DIR="${INSTALL_DIR}/logs"; BACKUP_DIR="${INSTALL_DIR}/backups"; ETC_DIR="/etc/hkvm"; ENV_FILE="${ETC_DIR}/hkvm.env"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"; PID_FILE="${INSTALL_DIR}/hkvm.pid"; PANEL_PORT="8080"; NODE_MAJOR_REQUIRED="20"
TMP_DIR=""
line(){ echo -e "${MAGENTA}============================================================${NC}"; }; info(){ echo -e "${CYAN}[INFO]${NC} $*"; }; ok(){ echo -e "${GREEN}[OK]${NC} $*"; }; warn(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }; error(){ echo -e "${RED}[ERROR]${NC} $*"; }; die(){ error "$*"; exit 1; }
cleanup(){ [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "$TMP_DIR" || true; }; trap cleanup EXIT
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
          ULTRA INSTALLER
EOF
printf '%b\n' "${NC}"; line
[[ ${EUID} -eq 0 ]] || die "Please run this installer as root."; ok "Root access detected."
[[ -f /etc/os-release ]] || die "Unable to detect operating system."; source /etc/os-release
info "Operating System : ${PRETTY_NAME:-unknown}"; info "Architecture     : $(uname -m)"; info "Kernel           : $(uname -r)"
if [[ "${ID:-}" != ubuntu && "${ID:-}" != debian ]]; then warn "This installer is designed for Debian/Ubuntu."; read -r -p "Continue anyway? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || die "Installation cancelled."; fi
HAS_SYSTEMD=false
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=true; ok "systemd detected."; else warn "systemd not detected — standalone/background mode enabled."; info "This is expected in Google Cloud Shell and many containers."; fi
line
export DEBIAN_FRONTEND=noninteractive
info "Installing required packages..."; apt-get update -y; apt-get install -y ca-certificates curl git unzip file lsof procps iproute2 sudo openssl build-essential; ok "Base dependencies installed."
NODE_OK=false
if command -v node >/dev/null 2>&1; then NODE_VERSION="$(node -v | sed 's/^v//')"; NODE_MAJOR="${NODE_VERSION%%.*}"; info "Detected Node.js: v${NODE_VERSION}"; [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] && (( NODE_MAJOR >= NODE_MAJOR_REQUIRED )) && NODE_OK=true; fi
if [[ "$NODE_OK" != true ]]; then info "Installing Node.js 22..."; curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; apt-get install -y nodejs; fi
command -v node >/dev/null 2>&1 || die "Node.js installation failed."; command -v npm >/dev/null 2>&1 || die "npm installation failed."; ok "Node.js: $(node -v) | npm: $(npm -v)"; line
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR" "$ETC_DIR"; chmod 755 "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"; chmod 700 "$BACKUP_DIR" "$ETC_DIR"
if [[ -f "$ENV_FILE" ]]; then cp -a "$ENV_FILE" "${BACKUP_DIR}/hkvm.env.$(date +%Y%m%d-%H%M%S).bak"; ok "Existing configuration backed up."; fi
if [[ "$HAS_SYSTEMD" == true ]]; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; elif [[ -f "$PID_FILE" ]]; then OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"; [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill "$OLD_PID" >/dev/null 2>&1 || true; rm -f "$PID_FILE"; fi
TMP_DIR="$(mktemp -d -t hkvm-installer-XXXXXX)"; REPO_DIR="${TMP_DIR}/repo"; EXTRACT_DIR="${TMP_DIR}/extracted"; mkdir -p "$EXTRACT_DIR"
info "Cloning HKVM repository..."; git clone --depth 1 --single-branch "$REPO_URL" "$REPO_DIR"; ok "Repository cloned."
ZIP_FILE="${REPO_DIR}/${ZIP_NAME}"; [[ -f "$ZIP_FILE" ]] || die "$ZIP_NAME was not found in the repository."; ZIP_SIZE="$(du -m "$ZIP_FILE" | awk '{print $1}')"; info "Found ${ZIP_NAME} (${ZIP_SIZE} MB)."; [[ "$ZIP_SIZE" -ge 1 ]] || die "ZIP file is empty or invalid."
info "Extracting ${ZIP_NAME}..."; unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"; ok "ZIP extracted."

# Robust application detection. NEVER use anything below node_modules.
# Prefer a package.json that has a real start script/main AND whose directory
# itself contains application source files. If the ZIP has a top-level Hkvm/
# directory, prefer it over dependency packages.
mapfile -t PACKAGE_FILES < <(find "$EXTRACT_DIR" -type f -name package.json -print | awk '!/\/node_modules\// && !/\/\.git\// {print}' | sort)
[[ ${#PACKAGE_FILES[@]} -gt 0 ]] || die "No application package.json found outside node_modules."

SOURCE_DIR=""
PACKAGE_JSON=""
for candidate in "${PACKAGE_FILES[@]}"; do
  dir="$(dirname "$candidate")"
  # Hard safety check against the exact failure seen previously.
  [[ "$dir" == *"/node_modules/"* ]] && continue
  has_start_or_main=false
  if node -e 'const p=require(process.argv[1]); process.exit((p.scripts&&typeof p.scripts.start==="string"&&p.scripts.start.trim())||p.main?0:1)' "$candidate" >/dev/null 2>&1; then has_start_or_main=true; fi
  if [[ "$has_start_or_main" == true ]]; then PACKAGE_JSON="$candidate"; SOURCE_DIR="$dir"; break; fi
done

# If package metadata is incomplete, prefer a top-level extracted app directory
# containing common Node entry files, again excluding node_modules.
if [[ -z "$SOURCE_DIR" ]]; then
  mapfile -t ENTRY_FILES < <(find "$EXTRACT_DIR" -type f \( -name app.js -o -name server.js -o -name index.js -o -name main.js \) -not -path '*/node_modules/*' -not -path '*/.git/*' -print | sort)
  for entry in "${ENTRY_FILES[@]}"; do
    dir="$(dirname "$entry")"; [[ "$dir" == *"/node_modules/"* ]] && continue
    SOURCE_DIR="$dir"; break
  done
fi

[[ -n "$SOURCE_DIR" ]] || die "Unable to locate HKVM application source in ${ZIP_NAME}."
info "Detected application directory: ${SOURCE_DIR}"
if [[ "$SOURCE_DIR" == *"/node_modules/"* ]]; then die "Safety check failed: application directory is inside node_modules."; fi
rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"; cp -a "${SOURCE_DIR}/." "$APP_DIR/"; ok "Application installed into ${APP_DIR}."

cd "$APP_DIR"
[[ -f package.json ]] || die "Detected application directory has no package.json."
info "Installing Node.js dependencies..."
if [[ -f package-lock.json ]]; then if ! npm ci --omit=dev; then warn "npm ci failed; retrying with npm install..."; npm install --omit=dev; fi; else npm install --omit=dev; fi
ok "Node.js dependencies installed."; line
LICENSE_MODE="required"; LICENSE_KEY=""
if [[ -f "$ENV_FILE" ]]; then OLD_MODE="$(grep '^LICENSE_MODE=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"; OLD_KEY="$(grep '^LICENSE_KEY=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"; [[ -n "$OLD_MODE" ]] && LICENSE_MODE="$OLD_MODE"; [[ -n "$OLD_KEY" ]] && LICENSE_KEY="$OLD_KEY"; fi
echo; echo -e "${CYAN}HKVM LICENSE CONFIGURATION${NC}"; if [[ -z "$LICENSE_KEY" ]]; then read -r -s -p "Enter HKVM license key: " LICENSE_KEY; echo; fi
if [[ -z "$LICENSE_KEY" ]]; then warn "No license key supplied."; read -r -p "Use LICENSE_MODE=disabled for development? [y/N]: " disable_license; if [[ "$disable_license" =~ ^[Yy]$ ]]; then LICENSE_MODE="disabled"; else die "A license key is required for production installation."; fi; else LICENSE_MODE="required"; ok "License configuration received."; fi
SESSION_SECRET="$(openssl rand -hex 32)"; [[ -n "$SESSION_SECRET" ]] || die "Failed to generate session secret."
cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
PANEL_NAME=HKVM
HKVM_DATA_DIR=${DATA_DIR}
SESSION_SECRET=${SESSION_SECRET}
LICENSE_MODE=${LICENSE_MODE}
LICENSE_KEY=${LICENSE_KEY}
HKVM_INSTALL_DIR=${INSTALL_DIR}
HKVM_APP_DIR=${APP_DIR}
HKVM_LOG_DIR=${LOG_DIR}
EOF
chmod 600 "$ENV_FILE"; chown root:root "$ENV_FILE"; rm -f "$APP_DIR/.env"; ln -s "$ENV_FILE" "$APP_DIR/.env"; ok "Secure HKVM configuration created."; line

START_SCRIPT="$(node -e 'const p=require("./package.json"); process.stdout.write((p.scripts&&p.scripts.start)||"")' 2>/dev/null || true)"; MAIN_FILE="$(node -e 'const p=require("./package.json"); process.stdout.write(p.main||"")' 2>/dev/null || true)"
if [[ -n "$START_SCRIPT" ]]; then EXEC_START="$(command -v npm) start"; info "Using npm start."; elif [[ -n "$MAIN_FILE" && -f "$APP_DIR/$MAIN_FILE" ]]; then EXEC_START="$(command -v node) $APP_DIR/$MAIN_FILE"; info "Using package.json main: $MAIN_FILE"; else ENTRY_FILE=""; for candidate in app.js server.js index.js main.js; do [[ -f "$APP_DIR/$candidate" ]] && { ENTRY_FILE="$APP_DIR/$candidate"; break; }; done; [[ -n "$ENTRY_FILE" ]] || die "Unable to detect application entrypoint."; EXEC_START="$(command -v node) $ENTRY_FILE"; info "Using Node entrypoint: $ENTRY_FILE"; fi
LOG_FILE="${LOG_DIR}/hkvm.log"; touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
if command -v ufw >/dev/null 2>&1; then ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi

if [[ "$HAS_SYSTEMD" == true ]]; then
  info "Creating systemd service..."; cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=HKVM Panel V3
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_START}
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
  chmod 644 "$SERVICE_FILE"; systemctl daemon-reload; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; systemctl restart "$SERVICE_NAME"; sleep 4
  if systemctl is-active --quiet "$SERVICE_NAME"; then ok "HKVM service is ONLINE."; else error "HKVM service failed to start."; journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true; exit 1; fi
else
  info "Starting HKVM in standalone/background mode..."; cd "$APP_DIR"; : > "$LOG_FILE"
  set +e; nohup bash -c "set -a; source '$ENV_FILE'; set +a; exec $EXEC_START" >>"$LOG_FILE" 2>&1 & HKVM_PID=$!; set -e; echo "$HKVM_PID" > "$PID_FILE"; sleep 5
  if kill -0 "$HKVM_PID" >/dev/null 2>&1; then ok "HKVM process is running (PID ${HKVM_PID})."; else error "HKVM process exited during startup."; echo; echo "---------------- HKVM STARTUP LOG ----------------"; tail -n 160 "$LOG_FILE" || true; echo "---------------------------------------------------"; echo; die "HKVM failed to start. The startup log above contains the real error."; fi
fi
PANEL_STATUS="OFFLINE"; for _ in {1..15}; do if ss -ltn 2>/dev/null | grep -q ":${PANEL_PORT}\b"; then PANEL_STATUS="ONLINE"; break; fi; sleep 1; done
PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"; [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_SERVER_IP"
clear 2>/dev/null || true
echo -e "${GREEN}"; cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                    HKVM PANEL V3                           ║
║                  INSTALLATION COMPLETE                    ║
╚════════════════════════════════════════════════════════════╝

  STATUS              : ${PANEL_STATUS}
  LICENSE STATUS      : ${LICENSE_MODE^^}
  PANEL URL           : http://${PUBLIC_IP}:${PANEL_PORT}
  INSTALL DIRECTORY   : ${INSTALL_DIR}
  APPLICATION         : ${APP_DIR}
  LOG FILE            : ${LOG_FILE}
  MODE                : $([[ "$HAS_SYSTEMD" == true ]] && echo SYSTEMD || echo STANDALONE)

  VPS: systemctl restart ${SERVICE_NAME} | systemctl status ${SERVICE_NAME}
  CLOUD SHELL: cat ${PID_FILE} | tail -f ${LOG_FILE}

  SOURCE REPOSITORY: ${REPO_URL}
  NOTE: The actual license key is never displayed.

╚════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"; [[ "$PANEL_STATUS" == ONLINE ]] && ok "HKVM Panel is listening on port ${PANEL_PORT}." || warn "HKVM started but port ${PANEL_PORT} is not listening yet."; line; echo -e "${CYAN}HKVM installation finished.${NC}"
