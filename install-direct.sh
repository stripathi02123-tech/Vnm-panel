#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM/HKVM direct installer + optional Cloudflare Tunnel
#
# Default:
#   http://SERVER_IP:8080
#
# Optional Cloudflare mode:
#   Panel still listens on 8080
#   cloudflared publishes the configured hostname
#
# For Cloudflare mode, use a remotely-managed Cloudflare Tunnel token.
# The tunnel's Public Hostname/origin should already point to:
#   http://127.0.0.1:8080
# ============================================================================

readonly CORE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install.sh'
readonly TMP="/tmp/hkvm-install-$$.sh"
readonly APP_DIR='/opt/hkvm/app'
readonly DATA_DIR='/opt/hkvm/data'
readonly LOG_DIR='/opt/hkvm/logs'
readonly DB_CANDIDATES=(
    '/root/.vnm/vnm.db'
    '/opt/hkvm/data/vnm.db'
    '/opt/hkvm/app/data/vnm.db'
)
readonly PORT="${PORT:-8080}"

readonly CLOUDFLARED_BIN='/usr/local/bin/cloudflared'
readonly CLOUDFLARED_CONFIG_DIR='/etc/cloudflared'
readonly CLOUDFLARED_TOKEN_FILE="${CLOUDFLARED_CONFIG_DIR}/vnm-tunnel.token"
readonly CLOUDFLARED_SERVICE='/etc/systemd/system/vnm-cloudflared.service'
readonly CLOUDFLARED_LOG_DIR='/var/log/cloudflared'
readonly CLOUDFLARED_PID_FILE='/opt/hkvm/cloudflared.pid'

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
NC='\033[0m'

DOMAIN_MODE='direct'
DOMAIN=''
CLOUDFLARE_TOKEN=''
CLOUDFLARE_ENABLED='false'
HAS_SYSTEMD='false'

info(){ printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARNING]${NC} $*"; }
die(){ printf '%b\n' "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

cleanup(){
    rm -f "${TMP}" || true
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die 'Run as root.'
command -v curl >/dev/null 2>&1 || die 'curl is required.'

detect_systemd(){
    local init_name
    init_name="$(ps -p 1 -o comm= 2>/dev/null || true)"

    if command -v systemctl >/dev/null 2>&1 &&
       [[ -d /run/systemd/system ]] &&
       [[ "${init_name}" == 'systemd' ]]; then
        HAS_SYSTEMD='true'
    else
        HAS_SYSTEMD='false'
    fi
}

prompt_domain_mode(){
    printf '\n%b\n' "${MAGENTA}============================================================${NC}"
    printf '%b\n' "${CYAN}VNM/HKVM ACCESS MODE${NC}"
    printf '%b\n\n' "${MAGENTA}============================================================${NC}"

    printf '  1) Direct IP  - http://SERVER_IP:%s\n' "${PORT}"
    printf '  2) Cloudflare - domain via cloudflared (panel still uses :%s)\n\n' "${PORT}"

    local choice
    read -r -p 'Choose [1/2] (default: 1): ' choice
    choice="${choice:-1}"

    case "${choice}" in
        1)
            DOMAIN_MODE='direct'
            CLOUDFLARE_ENABLED='false'
            ;;
        2)
            DOMAIN_MODE='cloudflare'
            CLOUDFLARE_ENABLED='true'

            read -r -p 'Cloudflare domain (example: panel.example.com): ' DOMAIN
            [[ -n "${DOMAIN}" ]] || die 'Cloudflare domain cannot be empty.'

            DOMAIN="${DOMAIN#http://}"
            DOMAIN="${DOMAIN#https://}"
            DOMAIN="${DOMAIN%%/*}"

            [[ "${DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
                die 'Invalid domain/hostname.'

            printf '\n'
            warn 'Cloudflare Tunnel must already be configured with this hostname.'
            warn "Set its origin/service to: http://127.0.0.1:${PORT}"
            warn 'The installer only installs/runs the tunnel connector on this server.'
            printf '\n'

            read -r -s -p 'Cloudflare Tunnel token: ' CLOUDFLARE_TOKEN
            printf '\n'
            [[ -n "${CLOUDFLARE_TOKEN}" ]] || die 'Cloudflare Tunnel token cannot be empty.'
            ;;
        *)
            die 'Invalid choice. Enter 1 or 2.'
            ;;
    esac
}

download_core(){
    info 'Downloading current install.sh...'
    curl -fsSL "${CORE_URL}" -o "${TMP}"
    chmod 700 "${TMP}"
    ok 'Installer downloaded.'
}

install_core(){
    info "Running VNM/HKVM core installer with port ${PORT}..."
    "${TMP}" "$@"
}

verify_core(){
    [[ -f "${APP_DIR}/app.js" ]] || die 'HKVM app.js was not installed.'
    [[ -d "${APP_DIR}/node_modules/bcryptjs" ]] || die 'bcryptjs is missing.'
    [[ -d "${APP_DIR}/node_modules/sqlite3" ]] || die 'sqlite3 is missing.'

    NODE_BIN="$(command -v node || true)"
    [[ -n "${NODE_BIN}" && -x "${NODE_BIN}" ]] ||
        die 'Node.js is not available after installation.'
    NODE_BIN="$(readlink -f "${NODE_BIN}" 2>/dev/null || printf '%s' "${NODE_BIN}")"

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 ||
            die "HKVM is not listening on port ${PORT}."
    fi

    ok "HKVM is listening on port ${PORT}."
}

locate_database(){
    info 'Locating the live VNM database...'

    DB_FILE=''
    for candidate in "${DB_CANDIDATES[@]}"; do
        if [[ -f "${candidate}" ]]; then
            DB_FILE="${candidate}"
            break
        fi
    done

    if [[ -z "${DB_FILE}" ]]; then
        DB_FILE="$(find /root /opt/hkvm \
            -type f \
            -name 'vnm.db' \
            -not -path '*/node_modules/*' \
            -not -path '*/tmp/*' \
            -print -quit 2>/dev/null || true)"
    fi

    [[ -n "${DB_FILE}" && -f "${DB_FILE}" ]] ||
        die 'Live VNM database could not be found.'

    ok "Database: ${DB_FILE}"
}

refresh_admin_credentials(){
    info 'Generating fresh admin password...'

    ADMIN_PASSWORD="$("${NODE_BIN}" -e \
        'process.stdout.write(require("crypto").randomBytes(18).toString("base64url"))')"

    [[ "${#ADMIN_PASSWORD}" -ge 20 ]] ||
        die 'Admin password generation failed.'

    export APP_DIR DB_FILE ADMIN_PASSWORD

    info 'Writing and verifying admin credentials...'

    "${NODE_BIN}" <<'NODE'
const bcrypt = require(`${process.env.APP_DIR}/node_modules/bcryptjs`);
const sqlite3 = require(`${process.env.APP_DIR}/node_modules/sqlite3`);

const db = new sqlite3.Database(process.env.DB_FILE);
const username = 'admin';
const password = process.env.ADMIN_PASSWORD;
const hash = bcrypt.hashSync(password, 12);

function fail(message) {
  console.error(`[ERROR] ${message}`);
  db.close(() => process.exit(1));
}

if (!password || password.length < 12) {
  fail('Generated password is invalid.');
}

db.serialize(() => {
  db.run(
    `UPDATE users
     SET password = ?, role = 'admin', is_active = 1
     WHERE username = ?`,
    [hash, username],
    function (err) {
      if (err) return fail(err.message);

      if (this.changes === 0) {
        db.run(
          `INSERT INTO users
             (username, password, email, full_name, role, is_active)
           VALUES (?, ?, ?, ?, ?, 1)`,
          [
            username,
            hash,
            'admin@vnm.local',
            'Administrator',
            'admin'
          ],
          function (insertErr) {
            if (insertErr) return fail(insertErr.message);
            verify();
          }
        );
      } else {
        verify();
      }
    }
  );

  function verify() {
    db.get(
      `SELECT username, password, role, is_active
       FROM users
       WHERE username = ?`,
      [username],
      (err, row) => {
        if (err) return fail(err.message);
        if (!row) return fail('Admin row was not found after update/insert.');
        if (!bcrypt.compareSync(password, row.password)) {
          return fail('bcrypt password verification failed.');
        }
        if (row.role !== 'admin' || Number(row.is_active) !== 1) {
          return fail('Admin role/status verification failed.');
        }

        db.run(
          `DELETE FROM sessions
           WHERE user_id = (
             SELECT id FROM users WHERE username = ?
           )`,
          [username],
          () => db.close(() => {
            console.log('[ADMIN_CREDENTIALS_VERIFIED]');
            process.exit(0);
          })
        );
      }
    );
  }
});
NODE

    cat > /opt/hkvm/admin-credentials.txt <<EOF
VNM/HKVM Panel
Username: admin
Password: ${ADMIN_PASSWORD}
EOF
    chmod 600 /opt/hkvm/admin-credentials.txt

    ok 'Fresh admin credentials written and verified.'
}

install_cloudflared(){
    [[ "${DOMAIN_MODE}" == 'cloudflare' ]] || return 0

    info 'Installing Cloudflare Tunnel (cloudflared)...'

    mkdir -p "${CLOUDFLARED_CONFIG_DIR}" "${CLOUDFLARED_LOG_DIR}"
    chmod 700 "${CLOUDFLARED_CONFIG_DIR}" "${CLOUDFLARED_LOG_DIR}"

    if command -v cloudflared >/dev/null 2>&1; then
        local existing
        existing="$(command -v cloudflared)"
        if [[ -x "${existing}" ]]; then
            ln -sf "$(readlink -f "${existing}")" "${CLOUDFLARED_BIN}"
        fi
    fi

    if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
        local arch asset
        arch="$(uname -m)"

        case "${arch}" in
            x86_64|amd64)
                asset='cloudflared-linux-amd64'
                ;;
            aarch64|arm64)
                asset='cloudflared-linux-arm64'
                ;;
            armv7l|armv7)
                asset='cloudflared-linux-arm'
                ;;
            i386|i686)
                asset='cloudflared-linux-386'
                ;;
            *)
                die "Unsupported architecture for cloudflared: ${arch}"
                ;;
        esac

        curl -fL \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}" \
            -o "${CLOUDFLARED_BIN}"

        chmod 755 "${CLOUDFLARED_BIN}"
    fi

    "${CLOUDFLARED_BIN}" version
    ok 'cloudflared installed.'
}

configure_cloudflare(){
    [[ "${DOMAIN_MODE}" == 'cloudflare' ]] || return 0

    [[ -x "${CLOUDFLARED_BIN}" ]] ||
        die 'cloudflared binary is missing.'

    # Store the secret separately instead of putting the token directly
    # in the service command line.
    printf '%s\n' "${CLOUDFLARE_TOKEN}" > "${CLOUDFLARED_TOKEN_FILE}"
    chmod 600 "${CLOUDFLARED_TOKEN_FILE}"

    if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
        info 'Creating VNM Cloudflare Tunnel systemd service...'

        cat > "${CLOUDFLARED_SERVICE}" <<EOF
[Unit]
Description=VNM/HKVM Cloudflare Tunnel
After=network-online.target hkvm.service
Wants=network-online.target
Requires=hkvm.service

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --loglevel info --logfile ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log run --token-file ${CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CLOUDFLARED_TOKEN_FILE}
ReadWritePaths=${CLOUDFLARED_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

        chmod 600 "${CLOUDFLARED_SERVICE}"
        systemd-analyze verify "${CLOUDFLARED_SERVICE}" ||
            die 'Cloudflare systemd service validation failed.'

        systemctl daemon-reload
        systemctl enable vnm-cloudflared.service >/dev/null
        systemctl restart vnm-cloudflared.service

        local active='false'
        for _ in {1..20}; do
            if systemctl is-active --quiet vnm-cloudflared.service; then
                active='true'
                break
            fi
            sleep 1
        done

        [[ "${active}" == 'true' ]] ||
            die 'Cloudflare Tunnel service did not remain running.'

        ok 'Cloudflare Tunnel service is running.'
    else
        warn 'systemd is unavailable; starting cloudflared in background mode.'

        pkill -f "${CLOUDFLARED_BIN}" >/dev/null 2>&1 || true

        nohup "${CLOUDFLARED_BIN}" \
            tunnel \
            --loglevel info \
            --logfile "${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log" \
            run \
            --token-file "${CLOUDFLARED_TOKEN_FILE}" \
            >/dev/null 2>&1 &

        echo "$!" > "${CLOUDFLARED_PID_FILE}"
        chmod 600 "${CLOUDFLARED_PID_FILE}"

        sleep 3

        if kill -0 "$(cat "${CLOUDFLARED_PID_FILE}")" >/dev/null 2>&1; then
            ok 'Cloudflare Tunnel started in background mode.'
        else
            die 'Cloudflare Tunnel failed to start.'
        fi
    fi

    CLOUDFLARE_TOKEN=''
}

verify_cloudflare(){
    [[ "${DOMAIN_MODE}" == 'cloudflare' ]] || return 0

    info "Checking configured domain: ${DOMAIN}"

    local code='000'
    code="$(curl -ksS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 15 \
        "https://${DOMAIN}/" 2>/dev/null || true)"

    case "${code}" in
        2*|3*)
            ok "Cloudflare domain responded (HTTP ${code})."
            ;;
        4*|5*)
            warn "Domain responded with HTTP ${code}. The tunnel is installed, but the Cloudflare hostname/origin may still need checking."
            ;;
        *)
            warn "Could not verify ${DOMAIN} from this server yet."
            warn "Check Cloudflare Tunnel status and make sure the hostname routes to http://127.0.0.1:${PORT}."
            ;;
    esac
}

build_panel_url(){
    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        PANEL_URL="https://${DOMAIN}"
        return
    fi

    if [[ -n "${CODESPACE_NAME:-}" &&
          -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
        PANEL_URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    else
        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        PANEL_URL="http://${SERVER_IP:-YOUR_SERVER_IP}:${PORT}"
    fi
}

final_screen(){
    build_panel_url

    printf '\n%b\n' "${GREEN}"
    cat <<EOF
╔════════════════════════════════════════════════════════════╗
║                 VNM/HKVM INSTALL COMPLETE                 ║
╚════════════════════════════════════════════════════════════╝

  ACCESS MODE : ${DOMAIN_MODE^^}

  PANEL URL   : ${PANEL_URL}

  LOCAL ORIGIN:
    http://127.0.0.1:${PORT}

  ADMIN:
    Username  : admin
    Password  : ${ADMIN_PASSWORD}
    File      : /opt/hkvm/admin-credentials.txt

  VERIFY:
    ✓ Panel is listening on ${PORT}
    ✓ Fresh admin password written
    ✓ bcrypt password verification passed
    ✓ Old admin sessions invalidated
EOF

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        cat <<EOF

  CLOUDFLARE:
    Domain    : ${DOMAIN}
    Status    : CONFIGURED
    Service   : vnm-cloudflared.service
    Log       : ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log
    Token     : stored in ${CLOUDFLARED_TOKEN_FILE}

    IMPORTANT:
      Cloudflare Tunnel hostname must route to:
        http://127.0.0.1:${PORT}
EOF
    else
        cat <<EOF

  DIRECT MODE:
    No Cloudflare domain configured.
    Use:
      ${PANEL_URL}
EOF
    fi

    cat <<EOF

  SERVICES:
    Panel:
      systemctl status hkvm

    Cloudflare:
      systemctl status vnm-cloudflared

  Logs:
    Panel:
      tail -f /opt/hkvm/logs/hkvm.log
EOF

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        cat <<EOF
    Cloudflare:
      tail -f ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log
EOF
    fi

    cat <<'EOF'

╚════════════════════════════════════════════════════════════╝
EOF
    printf '%b\n' "${NC}"

    ok 'Installation and configuration completed.'
}

main(){
    detect_systemd
    prompt_domain_mode
    download_core
    install_core "$@"
    verify_core
    locate_database
    refresh_admin_credentials

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        install_cloudflared
        configure_cloudflare
        verify_cloudflare
    fi

    final_screen
}

main "$@"

╚════════════════════════════════════════════════════════════╝
EOF
printf '%b\n' "${NC}"
ok 'Installation and admin credential verification completed.'
