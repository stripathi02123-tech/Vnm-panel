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
# ADMIN CREDENTIAL DISPLAY / RECOVERY
# ============================================================================

if [[ "${rc}" -eq 0 ]]; then
    if [[ -f "${CREDENTIAL_FILE}" ]]; then
        printf '\n'
        printf '%b\n' "${GREEN}============================================================${NC}"
        printf '%b\n' "${CYAN}VNM PANEL ADMIN CREDENTIALS${NC}"
        printf '%b\n' "${GREEN}============================================================${NC}"
        cat "${CREDENTIAL_FILE}"
        printf '\n'
        info "Credentials file: ${CREDENTIAL_FILE}"
        info "To view them again: sudo cat ${CREDENTIAL_FILE}"
    else
        warn "Admin credential file was not created by the core installer: ${CREDENTIAL_FILE}"
        warn 'The panel may already have existing credentials. No existing password was overwritten by this wrapper.'
    fi
fi

exit "${rc}"
