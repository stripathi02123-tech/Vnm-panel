#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# VNM PANEL — STABLE INSTALLER ENTRYPOINT
#
# This entrypoint prepares the host first, then downloads the maintained
# VNM Panel core installer (install-v5.sh).
#
# Runtime-compatible HKVM_* variables and /opt/hkvm paths are preserved.
# Branding is owned by the core installer; this wrapper never rewrites shell
# identifiers or configuration assignments.
# ============================================================================

readonly CORE_URL='https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/install-v5.sh'
readonly TMP="/tmp/vnm-panel-install-v5-$$.sh"
readonly CORE_TMP="/tmp/vnm-panel-install-v5-core-$$.sh"

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
        *) die "VNM Panel currently requires Debian or Ubuntu for automatic package installation (detected: ${ID:-unknown})." ;;
    esac

    command -v apt-get >/dev/null 2>&1 || die 'apt-get is required on Debian/Ubuntu.'
    export DEBIAN_FRONTEND=noninteractive

    info 'VNM Panel prerequisite step 1/6: updating APT package lists...'
    apt-get update -y

    info 'VNM Panel prerequisite step 2/6: installing cloud-image-utils and genisoimage...'
    apt-get install -y cloud-image-utils genisoimage

    info 'VNM Panel prerequisite step 3/6: installing QEMU + OVMF...'
    apt-get install -y qemu-system-x86 qemu-utils ovmf

    info 'VNM Panel prerequisite step 4/6: verifying installed commands...'
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'qemu-system-x86_64 is missing.'
    command -v qemu-img >/dev/null 2>&1 || die 'qemu-img is missing.'
    command -v cloud-localds >/dev/null 2>&1 || warn 'cloud-localds is missing; cloud-init image creation may be unavailable.'

    qemu-system-x86_64 --version | head -n 1 || true

    info 'VNM Panel prerequisite step 5/6: checking /dev/kvm...'
    if [[ -e /dev/kvm ]]; then
        ls -l /dev/kvm || true
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            ok 'KVM OK — /dev/kvm is accessible.'
        else
            warn '/dev/kvm exists but is not readable/writable by root.'
        fi
    else
        warn 'KVM NOT AVAILABLE — /dev/kvm is missing. QEMU software emulation may still work.'
    fi

    info 'VNM Panel prerequisite step 6/6: checking kernel virtualization messages...'
    dmesg | grep -iE 'kvm|virtualiz' | tail -30 || true

    if [[ -r /dev/kvm && -x "$(command -v qemu-system-x86_64)" ]] && command -v timeout >/dev/null 2>&1; then
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

        if [[ "${test_rc}" -eq 0 || "${test_rc}" -eq 124 ]]; then
            ok 'QEMU/KVM functional test passed.'
        else
            warn "QEMU/KVM functional test returned exit code ${test_rc}."
            tail -30 /tmp/vnm-panel-qemu-test.log 2>/dev/null || true
        fi
        rm -f /tmp/vnm-panel-qemu-test.log || true
    else
        warn 'Skipping QEMU/KVM functional test because /dev/kvm or timeout is unavailable.'
    fi

    export VNM_PANEL_PREREQS_DONE='true'
    ok 'VNM Panel host prerequisites are installed.'
}

install_vnm_panel_prerequisites

# ============================================================================
# CORE INSTALLER
# ============================================================================

command -v curl >/dev/null 2>&1 || die 'curl is required after prerequisite installation.'

info 'Downloading the maintained VNM Panel core installer...'
curl -fsSL "${CORE_URL}" -o "${CORE_TMP}"
[[ -s "${CORE_TMP}" ]] || die 'Downloaded VNM Panel core installer is empty.'
chmod 700 "${CORE_TMP}"

# IMPORTANT: execute the maintained core installer as-is. Do not globally
# replace HKVM text, because HKVM_* names are valid runtime configuration keys.
cp -f "${CORE_TMP}" "${TMP}"
chmod 700 "${TMP}"

info 'Starting VNM Panel core installation...'
"${TMP}" "$@"
rc=$?
exit "${rc}"
