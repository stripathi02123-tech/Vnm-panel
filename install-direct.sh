#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM PANEL — DIRECT INSTALLER BOOTSTRAP
#
# The existing VNM/HKVM direct-install flow is preserved. This wrapper only
# adds the required virtualization/bootstrap phase before the existing flow:
#   1. Install cloud-image-utils + genisoimage
#   2. Install qemu-system-x86 + qemu-utils + ovmf
#   3. Verify QEMU, /dev/kvm and cloud-localds/image tooling
#   4. Run a bounded KVM functional test when /dev/kvm is available
#   5. Execute the existing direct installer unchanged in behavior
#
# Runtime paths/service names remain compatible with the existing installation
# (/opt/hkvm and hkvm.service). Branding shown by the installer is VNM Panel.
# ============================================================================

readonly VNM_PANEL_LEGACY_COMMIT='dd9db741e4fac2394a514bae2c0d4ef933e00540'
readonly VNM_PANEL_LEGACY_URL="https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/${VNM_PANEL_LEGACY_COMMIT}/install-direct.sh"
readonly VNM_PANEL_TMP="/tmp/vnm-panel-direct-$$.sh"
readonly VNM_PANEL_LEGACY_TMP="/tmp/vnm-panel-direct-legacy-$$.sh"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
NC='\033[0m'

info(){ printf '%b\n' "${CYAN}[VNM PANEL][INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[VNM PANEL][OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[VNM PANEL][WARNING]${NC} $*"; }
die(){ printf '%b\n' "${RED}[VNM PANEL][ERROR]${NC} %s\n" "$*" >&2; exit 1; }

cleanup(){
    rm -f "${VNM_PANEL_TMP}" "${VNM_PANEL_LEGACY_TMP}" || true
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die 'Run this installer as root.'

# ============================================================================
# REQUIRED HOST PACKAGES — MUST RUN FIRST
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
        ubuntu|debian)
            ;;
        *)
            die "VNM Panel currently requires Debian or Ubuntu for automatic package installation (detected: ${ID:-unknown})."
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die 'apt-get is required on Debian/Ubuntu.'

    export DEBIAN_FRONTEND=noninteractive

    info 'VNM Panel prerequisite step 1/6: updating APT package lists...'
    apt-get update -y

    info 'VNM Panel prerequisite step 2/6: installing cloud-image-utils and genisoimage...'
    apt-get install -y cloud-image-utils genisoimage

    info 'VNM Panel prerequisite step 3/6: installing QEMU + OVMF...'
    apt-get install -y qemu-system-x86 qemu-utils ovmf

    info 'VNM Panel prerequisite step 4/6: verifying virtualization tools...'
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'qemu-system-x86_64 was not installed correctly.'
    command -v qemu-img >/dev/null 2>&1 || die 'qemu-img was not installed correctly.'
    command -v cloud-localds >/dev/null 2>&1 || warn 'cloud-localds is not available; cloud-init image generation may be unavailable.'

    if command -v genisoimage >/dev/null 2>&1; then
        ok 'genisoimage: $(command -v genisoimage)'
    elif command -v xorriso >/dev/null 2>&1; then
        ok 'xorriso available as ISO generation backend.'
    else
        warn 'No ISO generation utility was detected after installation.'
    fi

    qemu-system-x86_64 --version | head -n 1 || true

    info 'VNM Panel prerequisite step 5/6: checking /dev/kvm...'
    if [[ -e /dev/kvm ]]; then
        ls -l /dev/kvm || true
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            ok 'KVM device is available: /dev/kvm'
        else
            warn '/dev/kvm exists but is not readable/writable by root as expected.'
        fi
    else
        warn '/dev/kvm is not available. QEMU can still use software emulation, but hardware KVM acceleration will not be available.'
    fi

    info 'VNM Panel prerequisite step 6/6: checking kernel virtualization messages...'
    if command -v dmesg >/dev/null 2>&1; then
        dmesg | grep -iE 'kvm|virtualiz' | tail -30 || true
    fi

    if [[ -r /dev/kvm && -x "$(command -v qemu-system-x86_64)" ]]; then
        info 'Running bounded QEMU/KVM functional test...'
        set +e
        timeout 6s qemu-system-x86_64 \
            -accel kvm \
            -machine q35 \
            -display none \
            -nodefaults \
            -S \
            >/tmp/vnm-panel-qemu-test.log 2>&1
        local test_rc=$?
        set -e

        # -S intentionally keeps QEMU stopped, so timeout (124) is a valid
        # result: the process successfully entered the KVM/Q35 startup path.
        if [[ "${test_rc}" -eq 0 || "${test_rc}" -eq 124 ]]; then
            ok 'QEMU/KVM functional test completed successfully.'
        else
            warn "QEMU/KVM functional test returned exit code ${test_rc}."
            tail -30 /tmp/vnm-panel-qemu-test.log 2>/dev/null || true
        fi
        rm -f /tmp/vnm-panel-qemu-test.log || true
    else
        warn 'Skipping QEMU/KVM functional test because /dev/kvm is unavailable.'
    fi

    export VNM_PANEL_PREREQS_DONE='true'
    ok 'VNM Panel host prerequisites are ready.'
}

install_vnm_panel_prerequisites

# ============================================================================
# DOWNLOAD THE EXISTING DIRECT INSTALLER
# ============================================================================

command -v curl >/dev/null 2>&1 || die 'curl is required after prerequisite installation.'

info 'Downloading the existing VNM Panel direct-install flow...'
curl -fsSL "${VNM_PANEL_LEGACY_URL}" -o "${VNM_PANEL_LEGACY_TMP}"
[[ -s "${VNM_PANEL_LEGACY_TMP}" ]] || die 'Existing direct installer could not be downloaded.'
chmod 700 "${VNM_PANEL_LEGACY_TMP}"

# Keep the existing implementation/flow, while removing the old HKVM-only
# uppercase branding from what the user sees. Lowercase compatibility names
# such as /opt/hkvm and hkvm.service are deliberately untouched.
sed \
    -e 's/VNM\/HKVM/VNM PANEL/g' \
    -e 's/HKVM PANEL/VNM PANEL/g' \
    -e 's/HKVM/VNM PANEL/g' \
    "${VNM_PANEL_LEGACY_TMP}" > "${VNM_PANEL_TMP}"

chmod 700 "${VNM_PANEL_TMP}"

info 'Starting the existing VNM Panel direct installer...'
exec "${VNM_PANEL_TMP}" "$@"
