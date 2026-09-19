#!/usr/bin/env bash
# TrueNAS PREINIT script: activates hailo.raw sysext on every boot.
# Runs before middleware starts, so the Hailo device is ready before
# app containers (e.g., Frigate) launch.
#
# Stored on persistent pool; registered via midclt during install.
# Idempotent — safe to run on every boot.
#
# The hailo.raw squashfs contains firmware (injected at install time),
# so restoring the sysext also restores firmware. No separate firmware
# handling is needed.


set -euo pipefail

log() {
    echo "[hailo-preinit] $*"
    logger -t hailo-preinit "$*" 2>/dev/null || true
}

# --- Find persistent config via glob ---
# nullglob: if no pool matches, the loop body never runs (instead of
# iterating once with the literal glob string). Localized via subshell-free
# save/restore so the rest of the script keeps default globbing.
PERSIST_DIR=""
PERSIST_DIRS=()
shopt -s nullglob
for d in /mnt/*/.config/hailo; do
    [ -d "$d" ] && PERSIST_DIRS+=("$d")
done
shopt -u nullglob

if [ ${#PERSIST_DIRS[@]} -eq 0 ]; then
    log "No persistent config found at /mnt/*/.config/hailo/, nothing to do"
    exit 0
fi
if [ ${#PERSIST_DIRS[@]} -gt 1 ]; then
    log "WARNING: hailo config found on ${#PERSIST_DIRS[@]} pools: ${PERSIST_DIRS[*]}"
    log "WARNING: using ${PERSIST_DIRS[0]} (alphabetically first). Remove duplicates to silence this warning."
fi
PERSIST_DIR="${PERSIST_DIRS[0]}"

# The persistent blob on the data pool is the sysext image itself; we point
# /run/extensions at it directly instead of copying it onto the boot pool.
# /usr is wiped on every TrueNAS update, so a boot-pool copy would not survive
# anyway, and writing to /usr means toggling its readonly ZFS property.
HAILO_RAW="${PERSIST_DIR}/hailo.raw"

# Read which repo this install came from (written by install.sh)
HAILO_REPO="truenas-community-sysexts/hailo8-support"
if [ -f "${PERSIST_DIR}/.hailo-repo" ]; then
    HAILO_REPO=$(cat "${PERSIST_DIR}/.hailo-repo" 2>/dev/null) || HAILO_REPO="truenas-community-sysexts/hailo8-support"
    [ -z "$HAILO_REPO" ] && HAILO_REPO="truenas-community-sysexts/hailo8-support"
    # Migrate stale slug left over from installs predating the org move.
    if [ "$HAILO_REPO" = "scyto/truenas-hailo" ]; then
        HAILO_REPO="truenas-community-sysexts/hailo8-support"
    fi
fi

if [ ! -f "$HAILO_RAW" ]; then
    log "No hailo.raw at ${HAILO_RAW}, nothing to do"
    exit 0
fi

# --- Activate sysext directly off the data pool ---
# /run/extensions is tmpfs (gone after reboot), so we recreate the symlink
# every boot. systemd-sysext loop-mounts the symlink target wherever it lives;
# loop_device_make_by_path() is filesystem-agnostic, so a ZFS data-pool path
# works the same as a boot-pool path.
log "Activating hailo sysext..."
mkdir -p /run/extensions
ln -sf "$HAILO_RAW" /run/extensions/hailo.raw
systemd-sysext refresh
ldconfig

# --- Check kernel version matches the module in the sysext ---
running_kver=$(uname -r)
HAILO_KO="/usr/lib/modules/${running_kver}/extra/hailo_pci.ko"
if [ -f "$HAILO_KO" ]; then
    if [ -e /sys/module/hailo_pci ]; then
        log "Hailo module already loaded, skipping insmod"
    else
        log "Loading Hailo module..."
        insmod_rc=0
        insmod_err=$(insmod "$HAILO_KO" 2>&1) || insmod_rc=$?
        if [ "$insmod_rc" -ne 0 ]; then
            log "ERROR: insmod hailo_pci failed (rc=${insmod_rc}): ${insmod_err:-no output from insmod}"
            log "ERROR: check 'dmesg | grep -i hailo' for the kernel reason; a TrueNAS update can introduce a driver/kernel ABI mismatch"
            log "ERROR: if so, install a hailo.raw release matching ${running_kver} from https://github.com/${HAILO_REPO}/releases"
        fi
    fi
else
    SYSEXT_KVER=""
    for d in /usr/lib/modules/*/; do
        [ -d "$d" ] || continue
        name=${d%/}
        name=${name##*/}
        if [ "$name" != "$running_kver" ] && [ -f "${d}extra/hailo_pci.ko" ]; then
            SYSEXT_KVER="$name"
            break
        fi
    done
    if [ -n "$SYSEXT_KVER" ]; then
        log "ERROR: Kernel version mismatch - running ${running_kver} but sysext has module for ${SYSEXT_KVER}"
        log "ERROR: TrueNAS was likely updated. Download a new hailo.raw release matching ${running_kver}"
        log "ERROR: Visit https://github.com/${HAILO_REPO}/releases"
    else
        log "WARNING: hailo_pci.ko not found at ${HAILO_KO}"
    fi
fi

# --- Reload udev rules from sysext so /dev/hailo0 gets correct permissions ---
log "Reloading udev rules..."
udevadm control --reload-rules 2>/dev/null || true
if [ -e /dev/hailo0 ]; then
    udevadm trigger /dev/hailo0 2>/dev/null || true
fi

log "Done"
exit 0
