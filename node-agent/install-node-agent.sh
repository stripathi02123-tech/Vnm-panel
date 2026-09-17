#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM PANEL NODE AGENT — INSTALLER
# Installs the dependency-free VNM Panel Node Agent on Debian/Ubuntu.
# ============================================================================

APP_DIR='/opt/vnm-panel-node-agent'
DATA_DIR='/var/lib/vnm-panel-node'
LOG_DIR='/var/log/vnm-panel-node'
ETC_DIR='/etc/vnm-panel-node'
ENV_FILE="${ETC_DIR}/agent.env"
SERVICE_FILE='/etc/systemd/system/vnm-panel-node-agent.service'
AGENT_SOURCE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/node-agent/vnm_node_agent.py'
AGENT_FILE="${APP_DIR}/vnm_node_agent.py"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info(){ printf '%b\n' "${CYAN}[VNM NODE AGENT][INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[VNM NODE AGENT][OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[VNM NODE AGENT][WARNING]${NC} $*"; }
die(){ printf '%b\n' "${RED}[VNM NODE AGENT][ERROR]${NC} %s\n" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die 'Run this installer as root.'
[[ -f /etc/os-release ]] || die 'Unable to detect operating system.'
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "VNM Panel Node Agent requires Debian/Ubuntu (detected: ${ID:-unknown})." ;;
esac

export DEBIAN_FRONTEND=noninteractive

info 'Updating APT package lists...'
apt-get update -y

info 'Installing VNM Panel Node Agent dependencies...'
apt-get install -y \
  ca-certificates curl python3 qemu-system-x86 qemu-utils ovmf \
  cloud-image-utils genisoimage util-linux procps iproute2

mkdir -p "${APP_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${ETC_DIR}" "${DATA_DIR}/vms"
chmod 755 "${APP_DIR}"
chmod 750 "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${ETC_DIR}"

info 'Downloading VNM Panel Node Agent...'
curl -fsSL "${AGENT_SOURCE_URL}?v=$(date +%s)" -o "${AGENT_FILE}.new"
[[ -s "${AGENT_FILE}.new" ]] || die 'Downloaded node agent is empty.'
chmod 755 "${AGENT_FILE}.new"
python3 -m py_compile "${AGENT_FILE}.new" || die 'Node Agent Python syntax validation failed.'
mv -f "${AGENT_FILE}.new" "${AGENT_FILE}"

if [[ ! -f "${ENV_FILE}" ]]; then
  API_KEY="$(openssl rand -hex 32)"
  cat > "${ENV_FILE}" <<EOF
VNM_NODE_HOST=0.0.0.0
VNM_NODE_PORT=9090
VNM_NODE_API_KEY=${API_KEY}
VNM_NODE_DB=${DATA_DIR}/vms.db
VNM_VM_ROOT=${DATA_DIR}/vms
VNM_NODE_LOG_DIR=${LOG_DIR}
EOF
  chmod 600 "${ENV_FILE}"
  info 'Generated a new Node Agent API key.'
else
  chmod 600 "${ENV_FILE}"
  info 'Keeping existing Node Agent configuration.'
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VNM Panel Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 ${AGENT_FILE}
WorkingDirectory=${APP_DIR}
Restart=always
RestartSec=3
User=root
Group=root
NoNewPrivileges=false
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${SERVICE_FILE}"
systemd-analyze verify "${SERVICE_FILE}" || die 'systemd service validation failed.'
systemctl daemon-reload
systemctl enable vnm-panel-node-agent.service >/dev/null
systemctl restart vnm-panel-node-agent.service
sleep 2

if systemctl is-active --quiet vnm-panel-node-agent.service; then
  ok 'VNM Panel Node Agent is running.'
else
  systemctl status vnm-panel-node-agent.service --no-pager --full || true
  die 'VNM Panel Node Agent failed to start.'
fi

QEMU_VERSION="$(qemu-system-x86_64 --version | head -n 1 || true)"
KVM_STATE='NOT AVAILABLE'
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_STATE='AVAILABLE'
fi

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' '                 VNM PANEL NODE AGENT'
printf '%s\n' '                 INSTALLATION COMPLETE'
printf '%s\n' '============================================================'
printf '\n'
printf '  Agent URL        : http://YOUR_NODE_IP:9090\n'
printf '  Health           : http://YOUR_NODE_IP:9090/health\n'
printf '  Status API       : /api/v1/status\n'
printf '  VM API           : /api/v1/vms\n'
printf '  Config           : %s\n' "${ENV_FILE}"
printf '  Data             : %s\n' "${DATA_DIR}"
printf '  Logs             : %s\n' "${LOG_DIR}"
printf '  KVM              : %s\n' "${KVM_STATE}"
printf '  QEMU             : %s\n' "${QEMU_VERSION:-unavailable}"
printf '\n'
printf '  API KEY (store securely):\n'
printf '    %s\n' "$(awk -F= '$1=="VNM_NODE_API_KEY"{print substr($0,index($0,"=")+1)}' "${ENV_FILE}")"
printf '\n'
printf '  Service commands:\n'
printf '    systemctl status vnm-panel-node-agent\n'
printf '    systemctl restart vnm-panel-node-agent\n'
printf '    journalctl -u vnm-panel-node-agent -f\n'
printf '%s\n' '============================================================'
