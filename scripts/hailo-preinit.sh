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

USR_WAS_WRITABLE=0
USR_DATASET=""

restore_usr_readonly() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
}
trap restore_usr_readonly EXIT INT TERM

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

HAILO_RAW_BACKUP="${PERSIST_DIR}/hailo.raw"
SYSEXT_TARGET="/usr/share/truenas/sysext-extensions/hailo.raw"

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

if [ ! -f "$HAILO_RAW_BACKUP" ]; then
    log "No hailo.raw backup at ${HAILO_RAW_BACKUP}, nothing to do"
    exit 0
fi

# --- Compare checksums and reinstall if needed ---
NEED_COPY=true
if [ -f "$SYSEXT_TARGET" ]; then
    INSTALLED_SUM=$(sha256sum "$SYSEXT_TARGET" | awk '{print $1}')
    BACKUP_SUM=$(sha256sum "$HAILO_RAW_BACKUP" | awk '{print $1}')
    if [ -z "$INSTALLED_SUM" ] || [ -z "$BACKUP_SUM" ]; then
        log "WARNING: failed to read sha256 (installed='${INSTALLED_SUM}', backup='${BACKUP_SUM}'); reinstalling defensively"
    elif [ "$INSTALLED_SUM" = "$BACKUP_SUM" ]; then
        log "hailo.raw already matches backup, skipping copy"
        NEED_COPY=false
    else
        log "hailo.raw differs from backup (update detected), reinstalling..."
    fi
else
    log "hailo.raw missing, installing from backup..."
fi

if [ "$NEED_COPY" = true ]; then
    log "Removing old hailo sysext..."
    rm -f /run/extensions/hailo.raw
    systemd-sysext unmerge 2>/dev/null || true

    log "Making /usr writable..."
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null) || true
    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=off "$USR_DATASET"
        USR_WAS_WRITABLE=1
    fi

    log "Copying hailo.raw from backup..."
    if ! cp "$HAILO_RAW_BACKUP" "$SYSEXT_TARGET"; then
        log "ERROR: Failed to copy hailo.raw from backup"
        exit 1
    fi

    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET"
        USR_WAS_WRITABLE=0
    fi
fi

# --- Always activate sysext (symlink is on tmpfs, gone after reboot) ---
log "Activating hailo sysext..."
mkdir -p /run/extensions
ln -sf "$SYSEXT_TARGET" /run/extensions/hailo.raw
systemd-sysext refresh
ldconfig

# --- Check kernel version matches the module in the sysext ---
running_kver=$(uname -r)
HAILO_KO="/usr/lib/modules/${running_kver}/extra/hailo_pci.ko"
if [ -f "$HAILO_KO" ]; then
    log "Loading Hailo module..."
    insmod "$HAILO_KO" || log "WARNING: insmod hailo_pci failed (device may not be present)"
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
        log "ERROR: Kernel version mismatch — running ${running_kver} but sysext has module for ${SYSEXT_KVER}"
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
