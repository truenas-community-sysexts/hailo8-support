#!/usr/bin/env bash
# Restores the original state by removing hailo.raw sysext.
# Run this to completely remove the Hailo-8 driver extension.

set -euo pipefail

# --- Parse CLI arguments ---
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --help)
            echo "Usage: sudo ./restore.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force    Proceed even if hailo_pci is in use (requires reboot afterward)"
            echo "  --help     Show this help"
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $arg (see --help)" >&2
            exit 2
            ;;
    esac
done

# Source shared library (provides hailo_init_script_lookup).
# Try the sibling file first (checkout or extracted release); fall back to
# downloading from the release for backwards compat with old uninstall.sh
# callers that don't fetch hailo-lib.sh alongside restore.sh.
_source_hailo_lib() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/hailo-lib.sh" ]; then
        # shellcheck source=scripts/hailo-lib.sh
        source "${dir}/hailo-lib.sh"
        return 0
    fi
    local tmp repo
    repo="${HAILO_REPO:-truenas-community-sysexts/hailo8-support}"
    tmp=$(mktemp /tmp/hailo-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "https://github.com/${repo}/releases/latest/download/hailo-lib.sh" \
           -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # shellcheck source=scripts/hailo-lib.sh
        source "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}
_source_hailo_lib || {
    echo "ERROR: Could not load hailo-lib.sh (not found locally, download failed)." >&2
    echo "  Run from the release directory, or ensure network access to GitHub." >&2
    exit 1
}

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
HAILO_RAW="${SYSEXT_DIR}/hailo.raw"

# USR_WAS_WRITABLE: 1 while we have ${USR_DATASET}'s readonly=off and
# haven't restored it yet. `rm -f` rarely fails, but anything between
# off and on (including SIGINT/SIGTERM) should re-assert readonly so
# we don't leave /usr writable until reboot.
USR_WAS_WRITABLE=0
USR_DATASET=""

restore_usr_readonly() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
}
trap restore_usr_readonly EXIT INT TERM

echo "=== Removing Hailo-8 sysext ==="

# Pre-check: refuse to proceed if hailo_pci is in use unless --force is given.
# A held module means the backing .ko and libraries will be pulled out from
# under running consumers, leaving a half-state that confuses on next operation.
NEEDS_REBOOT=0
if lsmod 2>/dev/null | awk '{print $1}' | grep -qx hailo_pci; then
    REFCNT=$(lsmod | awk '$1 == "hailo_pci" {print $3}')
    if [ "${REFCNT:-0}" -gt 0 ]; then
        echo "hailo_pci is currently in use (refcount: ${REFCNT})."
        # Show which processes hold the device open
        if command -v fuser >/dev/null 2>&1; then
            PIDS=$(fuser /dev/hailo* 2>/dev/null | tr -s ' ') || true
            if [ -n "$PIDS" ]; then
                echo "  PIDs using /dev/hailo*: ${PIDS}"
                # Try to name the processes
                for pid in $PIDS; do
                    PNAME=$(ps -p "$pid" -o comm= 2>/dev/null) || PNAME="(unknown)"
                    echo "    PID ${pid}: ${PNAME}"
                done
            fi
        fi
        if [ "$FORCE" = "0" ]; then
            echo ""
            echo "ERROR: Refusing to remove sysext while hailo_pci is in use." >&2
            echo "  Stop the consuming process first (e.g. docker stop frigate)," >&2
            echo "  then re-run this script." >&2
            echo "  Or pass --force to remove anyway (reboot required afterward)." >&2
            exit 1
        fi
        echo ""
        echo "WARNING: --force given. Proceeding despite active consumers."
        echo "  The module will remain loaded in memory until reboot."
        echo "  A REBOOT IS REQUIRED to cleanly unload hailo_pci."
        NEEDS_REBOOT=1
    fi

    if [ "$NEEDS_REBOOT" = "0" ]; then
        echo "Unloading hailo_pci module..."
        if ! rmmod hailo_pci; then
            echo "WARNING: rmmod hailo_pci failed unexpectedly."
            if [ "$FORCE" = "0" ]; then
                echo "ERROR: Cannot unload module. Pass --force to continue anyway." >&2
                exit 1
            fi
            echo "  Continuing due to --force. A REBOOT IS REQUIRED."
            NEEDS_REBOOT=1
        fi
    fi
fi

# Remove hailo sysext symlink and unmerge so /usr can be remounted writable.
# Plain `systemd-sysext refresh` would re-merge any other active sysexts (e.g.
# the NVIDIA sysext on TrueNAS SCALE), which keeps the /usr overlay in place
# and makes the upcoming `zfs set readonly=off` fail.
echo "Removing hailo sysext..."
rm -f /run/extensions/hailo.raw
systemd-sysext unmerge 2>/dev/null || true

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null) || { echo "ERROR: Failed to find ZFS dataset for /usr (are you running as root?)"; exit 1; }
[ -z "$USR_DATASET" ] && { echo "ERROR: ZFS dataset for /usr is empty"; exit 1; }
zfs set readonly=off "${USR_DATASET}" || { echo "ERROR: Failed to make ${USR_DATASET} writable"; exit 1; }
USR_WAS_WRITABLE=1

# Remove hailo.raw
echo "Removing hailo.raw..."
rm -f "${HAILO_RAW}"

# Restore read-only
zfs set readonly=on "${USR_DATASET}"
USR_WAS_WRITABLE=0

# Re-merge any remaining sysexts (e.g. NVIDIA) that were deactivated by
# the earlier `systemd-sysext unmerge`. Without this, co-installed sysexts
# stay unmerged until the next reboot.
if ls /run/extensions/*.raw >/dev/null 2>&1; then
    echo "Re-merging remaining sysexts..."
    systemd-sysext refresh 2>/dev/null || echo "WARNING: Failed to re-merge remaining sysexts"
    ldconfig 2>/dev/null || true
fi

echo ""
echo "=== Restore complete ==="

# --- Clean up persistence ---
echo ""
echo "=== Cleaning up persistence ==="

# Deregister init script (preinit or legacy postinit). Treat midclt errors
# as "not found" — there's nothing safe to do if we can't query, and a stale
# entry the user can clean up manually beats a half-finished restore.
INIT_LOOKUP=$(hailo_init_script_lookup)
if [ "$INIT_LOOKUP" = "error" ]; then
    echo "WARNING: Could not query TrueNAS middleware — skipping init script deregistration"
    INIT_ID=""
else
    INIT_ID="${INIT_LOOKUP%%|*}"
fi

if [ -n "$INIT_ID" ]; then
    midclt call initshutdownscript.delete "$INIT_ID" 2>/dev/null \
        && echo "Init script deregistered (id: ${INIT_ID})" \
        || echo "WARNING: Failed to deregister init script"
elif [ "$INIT_LOOKUP" != "error" ]; then
    echo "No init script found to deregister"
fi

# Remove persistent config
for d in /mnt/*/.config/hailo; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"

if [ "$NEEDS_REBOOT" = "1" ]; then
    echo ""
    echo "============================================================"
    echo "  WARNING: hailo_pci was still in use when removed."
    echo "  The module remains loaded in memory but its backing files"
    echo "  are gone. A REBOOT IS REQUIRED to fully clean up."
    echo "  Stop any Hailo consumers (e.g. Frigate) before rebooting."
    echo "============================================================"
fi
