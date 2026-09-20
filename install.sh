#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM PANEL — STABLE INSTALLER ENTRYPOINT
#
# Host prerequisites run first, then the maintained VNM Panel core installer.
# Runtime-compatible HKVM_* variables and /opt/hkvm paths are preserved.
# This wrapper NEVER performs blanket branding replacements.
# ============================================================================

readonly CORE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install-v5.sh'
readonly TMP="/tmp/vnm-panel-install-v5-$$.sh"
readonly CORE_TMP="/tmp/vnm-panel-install-v5-core-$$.sh"
readonly CREDENTIAL_FILE='/opt/hkvm/admin-credentials.txt'

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info(){ printf '%b\n' "${CYAN}[VNM PANEL][INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[VNM PANEL][OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[VNM PANEL][WARNING]${NC} $*"; }
die(){ printf '%b\n' "${RED}[VNM PANEL][ERROR]${NC} %s\n" "$*" >&2; exit 1; }

cleanup(){ rm -f "${TMP}" "${CORE_TMP}" || true; }
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die 'Run the VNM Panel installer as root.'

# ============================================================================
# REQUIRED HOST PACKAGES — RUN BEFORE CORE INSTALLER
# ============================================================================

install_vnm_panel_prerequisites(){
    [[ "${VNM_PANEL_PREREQS_DONE:-false}" == 'true' ]] && {
        info 'VNM Panel host prerequisites were already installed by the parent installer.'
        return 0
    }

    [[ -f /etc/os-release ]] || die 'Unable to detect the operating system.'
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "VNM Panel requires Debian or Ubuntu for automatic package installation (detected: ${ID:-unknown})." ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die 'apt-get is required on Debian/Ubuntu.'
    export DEBIAN_FRONTEND=noninteractive

    info 'VNM Panel: updating APT package lists...'
    apt-get update -y

    info 'VNM Panel: installing cloud-image-utils + genisoimage...'
    apt-get install -y cloud-image-utils genisoimage

    info 'VNM Panel: installing QEMU + OVMF...'
    apt-get install -y qemu-system-x86 qemu-utils ovmf

    info 'VNM Panel: verifying virtualization tools...'
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'qemu-system-x86_64 is missing.'
    command -v qemu-img >/dev/null 2>&1 || die 'qemu-img is missing.'
    command -v cloud-localds >/dev/null 2>&1 || warn 'cloud-localds is missing; cloud-init image creation may be unavailable.'

    qemu-system-x86_64 --version | head -n 1 || true

    if [[ -e /dev/kvm ]]; then
        ls -l /dev/kvm || true
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            ok 'KVM OK — /dev/kvm is accessible.'
        else
            warn '/dev/kvm exists but is not readable/writable by root.'
        fi
    else
        warn 'KVM NOT AVAILABLE — QEMU software emulation may still work.'
    fi

    if [[ -r /dev/kvm && -x "$(command -v qemu-system-x86_64)" ]] && command -v timeout >/dev/null 2>&1; then
        info 'Running bounded QEMU/KVM functional test...'
        set +e
        timeout 6s qemu-system-x86_64 -accel kvm -machine q35 -display none -nodefaults -S >/tmp/vnm-panel-qemu-test.log 2>&1
        local test_rc=$?
        set -e
        if [[ "${test_rc}" -eq 0 || "${test_rc}" -eq 124 ]]; then
            ok 'QEMU/KVM functional test passed.'
        else
            warn "QEMU/KVM functional test returned exit code ${test_rc}."
            tail -30 /tmp/vnm-panel-qemu-test.log 2>/dev/null || true
        fi
        rm -f /tmp/vnm-panel-qemu-test.log || true
    fi

    export VNM_PANEL_PREREQS_DONE='true'
    ok 'VNM Panel host prerequisites are installed.'
}

install_vnm_panel_prerequisites

command -v curl >/dev/null 2>&1 || die 'curl is required after prerequisite installation.'

# Cache-bust the core download so a stale raw.githubusercontent.com copy cannot
# resurrect an older broken installer.
CORE_FETCH_URL="${CORE_URL}?v=$(date +%s)"
info 'Downloading the current VNM Panel core installer...'
curl -fsSL "${CORE_FETCH_URL}" -o "${CORE_TMP}"
[[ -s "${CORE_TMP}" ]] || die 'Downloaded VNM Panel core installer is empty.'
chmod 700 "${CORE_TMP}"

grep -Fq 'PANEL_NAME="VNM Panel"' "${CORE_TMP}" || die 'Downloaded core installer failed VNM Panel environment safety validation.'

# Never perform branding substitutions here. In particular, never replace
# the token HKVM globally because HKVM_* variables are functional identifiers.
cp -f "${CORE_TMP}" "${TMP}"
chmod 700 "${TMP}"

info 'Starting VNM Panel core installation...'
"${TMP}" "$@"
rc=$?

# ============================================================================
# ADMIN CREDENTIAL CREATION / DISPLAY / RECOVERY
# ============================================================================
#
# The V5 core installer starts the panel but does not seed the admin account.
# Keep that responsibility here so /opt/hkvm/admin-credentials.txt is always
# created from the same verified credentials that are stored in the database.
#
# The credential format intentionally matches the legacy working installer:
#   Username: admin
#   Password: <generated>
# ============================================================================
create_and_verify_admin_credentials(){
    local app_dir='/opt/hkvm/app'
    local credential_file='/opt/hkvm/admin-credentials.txt'
    local node_bin=''
    local db_file=''
    local generated_password=''
    local candidate=''

    command -v node >/dev/null 2>&1 || die 'Node.js is missing; cannot create admin credentials.'
    node_bin="$(readlink -f "$(command -v node)" 2>/dev/null || command -v node)"

    # The panel normally uses /root/.vnm/vnm.db, but preserve the known
    # compatibility locations used by previous VNM/HKVM installers.
    local candidates=(
        '/root/.vnm/vnm.db'
        '/opt/hkvm/data/vnm.db'
        '/opt/hkvm/app/data/vnm.db'
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}" ]]; then
            db_file="${candidate}"
            break
        fi
    done

    # The app creates its database during startup. Give it a bounded window
    # to finish initialization before declaring credential creation broken.
    if [[ -z "${db_file}" ]]; then
        info 'Waiting for the VNM Panel database to initialize...'
        for _ in {1..30}; do
            for candidate in "${candidates[@]}"; do
                if [[ -f "${candidate}" ]]; then
                    db_file="${candidate}"
                    break
                fi
            done
            [[ -n "${db_file}" ]] && break
            sleep 1
        done
    fi

    if [[ -z "${db_file}" ]]; then
        db_file="$(
            find /root /opt/hkvm \
                -type f -name 'vnm.db' \
                -not -path '*/node_modules/*' \
                -not -path '*/tmp/*' \
                -print -quit 2>/dev/null || true
        )"
    fi

    [[ -n "${db_file}" && -f "${db_file}" ]] || die 'Live VNM database could not be found; admin credentials were not generated.'
    [[ -d "${app_dir}/node_modules/bcryptjs" ]] || die 'bcryptjs is missing; admin credentials cannot be safely generated.'
    [[ -d "${app_dir}/node_modules/sqlite3" ]] || die 'sqlite3 is missing; admin credentials cannot be safely generated.'

    info "Using VNM Panel database: ${db_file}"
    info 'Generating and verifying fresh admin credentials...'

    generated_password="$(
        "${node_bin}" -e \
            'process.stdout.write(require("crypto").randomBytes(18).toString("base64url"))'
    )"

    [[ "${#generated_password}" -ge 20 ]] || die 'Admin password generation failed.'

    export VNM_APP_DIR="${app_dir}"
    export VNM_DB_FILE="${db_file}"
    export VNM_ADMIN_PASSWORD="${generated_password}"

    "${node_bin}" <<'NODE'
const bcrypt = require(`${process.env.VNM_APP_DIR}/node_modules/bcryptjs`);
const sqlite3 = require(`${process.env.VNM_APP_DIR}/node_modules/sqlite3`);

const db = new sqlite3.Database(process.env.VNM_DB_FILE);
const username = 'admin';
const password = process.env.VNM_ADMIN_PASSWORD;
const hash = bcrypt.hashSync(password, 12);

function fail(message) {
  console.error(`[VNM PANEL][ERROR] ${message}`);
  db.close(() => process.exit(1));
}

if (!password || password.length < 12) {
  fail('Generated admin password is invalid.');
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

        // Invalidate existing admin sessions so the newly generated password
        // is the only valid credential after installation.
        db.run(
          `DELETE FROM sessions
           WHERE user_id = (
             SELECT id FROM users WHERE username = ?
           )`,
          [username],
          () => {
            db.close(() => {
              console.log('[ADMIN_CREDENTIALS_VERIFIED]');
              process.exit(0);
            });
          }
        );
      }
    );
  }
});
NODE

    umask 077
    cat > "${credential_file}" <<EOF
VNM/HKVM Panel
Username: admin
Password: ${generated_password}
EOF
    chmod 600 "${credential_file}"
    chown root:root "${credential_file}"

    # Ensure the file itself is actually readable before reporting success.
    [[ -s "${credential_file}" ]] || die 'Admin credential file was not created.'
    grep -Fq 'Username: admin' "${credential_file}" || die 'Admin credential file is missing the username.'
    grep -Fq 'Password: ' "${credential_file}" || die 'Admin credential file is missing the password.'

    ok "Fresh admin credentials written and verified: ${credential_file}"
}

# ============================================================================
# ADMIN CREDENTIAL DISPLAY
# ============================================================================

if [[ "${rc}" -eq 0 ]]; then
    create_and_verify_admin_credentials

    printf '\n'
    printf '%b\n' "${GREEN}============================================================${NC}"
    printf '%b\n' "${CYAN}VNM PANEL ADMIN CREDENTIALS${NC}"
    printf '%b\n' "${GREEN}============================================================${NC}"
    cat '/opt/hkvm/admin-credentials.txt'
    printf '\n'
    info 'Credentials file: /opt/hkvm/admin-credentials.txt'
    info 'To view them again: sudo cat /opt/hkvm/admin-credentials.txt'
fi

exit "${rc}"
