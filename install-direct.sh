#!/usr/bin/env bash
set -Eeuo pipefail

# VNM/HKVM direct installer.
# Runs install.sh, then ALWAYS creates and verifies fresh admin credentials
# against the live SQLite database. It never trusts an old credentials file.

readonly CORE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install.sh'
readonly TMP='/tmp/hkvm-install-$$.sh'
readonly APP_DIR='/opt/hkvm/app'
readonly DATA_DIR='/opt/hkvm/data'
readonly LOG_DIR='/opt/hkvm/logs'
readonly DB_CANDIDATES=('/root/.vnm/vnm.db' '/opt/hkvm/data/vnm.db' '/opt/hkvm/app/data/vnm.db')
readonly PORT="${PORT:-8080}"

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
info(){ printf '%b\n' "${CYAN}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARNING]${NC} $*"; }
die(){ printf '%b\n' "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
cleanup(){ rm -f "${TMP}" || true; }
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die 'Run as root.'
command -v curl >/dev/null 2>&1 || die 'curl is required.'

info 'Downloading current install.sh...'
curl -fsSL "${CORE_URL}" -o "${TMP}"
chmod 700 "${TMP}"
ok 'Installer downloaded.'

"${TMP}" "$@"

[[ -f "${APP_DIR}/app.js" ]] || die 'HKVM app.js was not installed.'
[[ -d "${APP_DIR}/node_modules/bcryptjs" ]] || die 'bcryptjs is missing.'
[[ -d "${APP_DIR}/node_modules/sqlite3" ]] || die 'sqlite3 is missing.'

NODE_BIN="$(command -v node || true)"
[[ -n "${NODE_BIN}" && -x "${NODE_BIN}" ]] || die 'Node.js is not available after installation.'
NODE_BIN="$(readlink -f "${NODE_BIN}" 2>/dev/null || printf '%s' "${NODE_BIN}")"

if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 || die "HKVM is not listening on port ${PORT}."
fi

info 'Locating the live VNM database...'
DB_FILE=''
for candidate in "${DB_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
        DB_FILE="${candidate}"
        break
    fi
done

if [[ -z "${DB_FILE}" ]]; then
    DB_FILE="$(find /root /opt/hkvm -type f -name 'vnm.db' -not -path '*/node_modules/*' -not -path '*/tmp/*' -print -quit 2>/dev/null || true)"
fi

[[ -n "${DB_FILE}" && -f "${DB_FILE}" ]] || die 'Live VNM database could not be found.'
ok "Database: ${DB_FILE}"

info 'Generating fresh admin password...'
ADMIN_PASSWORD="$(${NODE_BIN} -e 'process.stdout.write(require("crypto").randomBytes(18).toString("base64url"))')"
[[ "${#ADMIN_PASSWORD}" -ge 20 ]] || die 'Admin password generation failed.'

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

if (!password || password.length < 12) fail('Generated password is invalid.');

db.serialize(() => {
  db.run(
    `UPDATE users SET password = ?, role = 'admin', is_active = 1 WHERE username = ?`,
    [hash, username],
    function (err) {
      if (err) return fail(err.message);
      if (this.changes === 0) {
        db.run(
          `INSERT INTO users (username, password, email, full_name, role, is_active)
           VALUES (?, ?, ?, ?, ?, 1)`,
          [username, hash, 'admin@vnm.local', 'Administrator', 'admin'],
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
      `SELECT username, password, role, is_active FROM users WHERE username = ?`,
      [username],
      (err, row) => {
        if (err) return fail(err.message);
        if (!row) return fail('Admin row was not found after update/insert.');
        if (!bcrypt.compareSync(password, row.password)) return fail('bcrypt password verification failed.');
        if (row.role !== 'admin' || Number(row.is_active) !== 1) return fail('Admin role/status verification failed.');

        db.run(
          `DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE username = ?)`,
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

if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    PANEL_URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    PANEL_URL="http://${SERVER_IP:-YOUR_SERVER_IP}:${PORT}"
fi

printf '\n%b\n' "${GREEN}"
cat <<EOF
╔════════════════════════════════════════════════════════════╗
║                 ADMIN LOGIN CREDENTIALS                   ║
╚════════════════════════════════════════════════════════════╝

  Username : admin
  Password : ${ADMIN_PASSWORD}
  Panel    : ${PANEL_URL}

  ✓ Password written to the live database
  ✓ bcrypt verification passed
  ✓ Old admin sessions invalidated

  Change the password after first login.

╚════════════════════════════════════════════════════════════╝
EOF
printf '%b\n' "${NC}"
ok 'Installation and admin credential verification completed.'
