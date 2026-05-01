#!/usr/bin/env bash
# Installs the pre-built hailo.raw sysext on a running TrueNAS system.
# All driver compilation happens on GitHub Actions — this script only
# downloads and places the pre-built hailo.raw file.
#
# Firmware is proprietary and not in the release. This script downloads it
# from Hailo's servers and injects it into the sysext squashfs at install time.
#
# Usage: curl -fsSL <release-url>/install.sh | sudo bash
#    or: sudo ./install.sh [path-to-hailo.raw]
#    or: sudo ./install.sh --pool=fast

set -euo pipefail

REPO="scyto/truenas-hailo"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
HAILO_RAW="${SYSEXT_DIR}/hailo.raw"

# --- Parse CLI arguments ---
LOCAL_RAW=""
POOL_NAME=""
PERSIST_PATH=""

for arg in "$@"; do
    case "$arg" in
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-hailo.raw]"
            echo ""
            echo "Options:"
            echo "  --pool=NAME              ZFS pool for persistent config (e.g., fast)"
            echo "  --persist-path=PATH      Exact path for persistent config"
            echo "  --help                   Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo ./install.sh --pool=fast"
            echo "  sudo ./install.sh /tmp/hailo.raw"
            echo "  curl -fsSL <url>/install.sh | sudo bash"
            exit 0
            ;;
        *)
            if [ -f "$arg" ]; then
                LOCAL_RAW="$arg"
            fi
            ;;
    esac
done

cleanup() {
    rm -f /tmp/hailo.raw /tmp/hailo.raw.sha256 /tmp/hailo8_fw.bin
    rm -rf /tmp/hailo-sysext-unpack
}
trap cleanup EXIT INT TERM

# If a local path is provided, use it; otherwise download from GitHub releases
if [ -n "$LOCAL_RAW" ]; then
    echo "Using local hailo.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" /tmp/hailo.raw
else
    # Detect TrueNAS version
    VERSION=$(midclt call system.info | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['version'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
") || { echo "ERROR: Failed to detect TrueNAS version"; exit 1; }
    [ -z "$VERSION" ] && { echo "ERROR: TrueNAS version is empty"; exit 1; }
    echo "Detected TrueNAS version: ${VERSION}"

    # Find matching release
    echo "Searching for matching release..."
    RELEASE_TAG=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
        | python3 -c "
import sys, json
try:
    releases = json.load(sys.stdin)
    version = '${VERSION}'
    matches = [r for r in releases if version in r['tag_name']]
    if not matches:
        print('', end='')
    else:
        print(matches[0]['tag_name'], end='')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
") || { echo "ERROR: Failed to query GitHub releases"; exit 1; }

    if [ -z "$RELEASE_TAG" ]; then
        echo "ERROR: No release found for TrueNAS version ${VERSION}"
        echo "Available releases:"
        curl -sf "https://api.github.com/repos/${REPO}/releases" \
            | python3 -c "import sys,json; [print(f'  {r[\"tag_name\"]}') for r in json.load(sys.stdin)]"
        exit 1
    fi

    echo "Found release: ${RELEASE_TAG}"

    # Download hailo.raw and checksum
    BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
    echo "Downloading hailo.raw..."
    curl -fSL "${BASE_URL}/hailo.raw" -o /tmp/hailo.raw || { echo "ERROR: Failed to download hailo.raw"; exit 1; }
    curl -fSL "${BASE_URL}/hailo.raw.sha256" -o /tmp/hailo.raw.sha256 || { echo "ERROR: Failed to download checksum"; exit 1; }

    # Validate downloads are non-empty
    [ -s /tmp/hailo.raw ] || { echo "ERROR: hailo.raw is empty"; exit 1; }
    [ -s /tmp/hailo.raw.sha256 ] || { echo "ERROR: checksum file is empty"; exit 1; }

    # Verify checksum
    echo "Verifying checksum..."
    if ! (cd /tmp && sha256sum -c hailo.raw.sha256); then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi
    echo "Checksum OK"
fi

# --- Download Hailo-8 firmware and inject into sysext ---
# Firmware is proprietary and not included in the release.
# We download it from Hailo's servers and inject it into the squashfs
# so it gets merged into the filesystem via systemd-sysext.
echo ""
echo "=== Downloading Hailo-8 firmware ==="

# Determine HailoRT version from release tag or .hailo-driver-version
HAILO_VERSION=""
if [ -n "${RELEASE_TAG:-}" ]; then
    # Extract version from tag like v25.10.2.1-hailo4.20.0
    HAILO_VERSION=$(echo "$RELEASE_TAG" | sed -n 's/.*hailo\([0-9.]*\)$/\1/p')
fi
if [ -z "$HAILO_VERSION" ]; then
    # Fallback: try to read from the repo's .hailo-driver-version
    HAILO_VERSION=$(curl -sf "https://raw.githubusercontent.com/${REPO}/main/.hailo-driver-version" | tr -d '[:space:]') || true
fi
if [ -z "$HAILO_VERSION" ]; then
    echo "WARNING: Could not determine HailoRT version, defaulting to 4.20.0"
    HAILO_VERSION="4.20.0"
fi

echo "HailoRT version: ${HAILO_VERSION}"
FW_URL="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/${HAILO_VERSION}/FW/hailo8_fw.${HAILO_VERSION}.bin"

echo "Downloading firmware from Hailo..."
if ! curl -fSL "$FW_URL" -o /tmp/hailo8_fw.bin; then
    echo "ERROR: Failed to download firmware from ${FW_URL}"
    echo "  Cannot install sysext without firmware — aborting."
    exit 1
fi
if [ ! -s /tmp/hailo8_fw.bin ]; then
    echo "ERROR: Downloaded firmware is empty — aborting."
    rm -f /tmp/hailo8_fw.bin
    exit 1
fi
echo "Firmware downloaded: $(ls -lh /tmp/hailo8_fw.bin)"

# --- Inject firmware into hailo.raw squashfs ---
echo "Injecting firmware into hailo.raw..."
if command -v unsquashfs &>/dev/null && command -v mksquashfs &>/dev/null; then
    unsquashfs -d /tmp/hailo-sysext-unpack /tmp/hailo.raw
    mkdir -p /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo
    cp /tmp/hailo8_fw.bin /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo/hailo8_fw.bin
    mksquashfs /tmp/hailo-sysext-unpack /tmp/hailo.raw -noappend -comp zstd
    rm -rf /tmp/hailo-sysext-unpack
    echo "Firmware injected into hailo.raw"
else
    echo "ERROR: squashfs-tools not found, cannot inject firmware into sysext"
    echo "  Install squashfs-tools: apt-get install squashfs-tools"
    exit 1
fi

echo ""
echo "=== Installing hailo.raw ==="

# Remove hailo from sysext before modifying
echo "Removing old hailo sysext symlink..."
rm -f /run/extensions/hailo.raw
systemd-sysext unmerge 2>/dev/null || true

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null) || { echo "ERROR: Failed to find ZFS dataset for /usr"; exit 1; }
[ -z "$USR_DATASET" ] && { echo "ERROR: ZFS dataset for /usr is empty"; exit 1; }
echo "Setting ${USR_DATASET} to writable..."
zfs set readonly=off "${USR_DATASET}" || { echo "ERROR: Failed to make ${USR_DATASET} writable"; exit 1; }

# Install new hailo.raw (backup is on persistent pool, no need for .bak)
echo "Installing new hailo.raw..."
cp /tmp/hailo.raw "${HAILO_RAW}"

# Restore read-only
zfs set readonly=on "${USR_DATASET}"

# Activate sysext via symlink + refresh (TrueNAS middleware pattern)
echo "Activating hailo sysext..."
mkdir -p /run/extensions
ln -sf "${HAILO_RAW}" /run/extensions/hailo.raw
systemd-sysext refresh
ldconfig

# Load the kernel module (use insmod directly — /lib/modules is read-only on TrueNAS
# so depmod can't update module deps, and modprobe can't find modules without it)
echo "Loading Hailo kernel module..."
HAILO_KO="/usr/lib/modules/$(uname -r)/extra/hailo_pci.ko"
if [ -f "$HAILO_KO" ]; then
    insmod "$HAILO_KO" || echo "WARNING: insmod hailo_pci failed (device may not be present)"
else
    echo "WARNING: hailo_pci.ko not found at ${HAILO_KO}"
fi

# Reload udev rules from sysext so /dev/hailo0 gets correct permissions
echo "Reloading udev rules..."
udevadm control --reload-rules 2>/dev/null || true
if [ -e /dev/hailo0 ]; then
    udevadm trigger /dev/hailo0 2>/dev/null || true
fi

echo ""
echo "=== Installation complete ==="
echo ""

# Verify
if [ -e /dev/hailo0 ]; then
    echo "Device /dev/hailo0 detected!"
    if command -v hailortcli &>/dev/null; then
        echo "Firmware identification:"
        hailortcli fw-control --identify 2>/dev/null || echo "(device query failed — may need reboot)"
    fi
else
    echo "Device /dev/hailo0 not found."
    echo "  - Ensure a Hailo-8 PCIe card is installed"
    echo "  - Try rebooting the system"
fi

# ==========================================================================
# Persistence setup — survives reboots and TrueNAS updates
# ==========================================================================

echo ""
echo "=== Setting up persistence ==="

# --- Detect persistent storage pool ---
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_DIR="$PERSIST_PATH"
elif [ -n "$POOL_NAME" ]; then
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/hailo"
else
    # Auto-detect: first pool that isn't boot-pool
    POOL_NAME=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1)
    if [ -n "$POOL_NAME" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/hailo"
        echo "Auto-detected pool: ${POOL_NAME}"
    else
        echo "WARNING: No ZFS pool found (excluding boot-pool). Skipping persistence setup."
        echo "  Re-run with --pool=<name> or --persist-path=<path> to enable persistence."
        exit 0
    fi
fi

echo "Persistent config directory: ${PERSIST_DIR}"
mkdir -p "$PERSIST_DIR"

# --- Backup hailo.raw (with firmware inside) to persistent storage ---
echo "Backing up hailo.raw to persistent storage..."
cp /tmp/hailo.raw "${PERSIST_DIR}/hailo.raw"

# Save HailoRT version for reference
echo -n "$HAILO_VERSION" > "${PERSIST_DIR}/.hailo-driver-version"

# --- Write PREINIT script to persistent storage ---
# NOTE: This is an inline copy of scripts/hailo-preinit.sh.
# Keep both copies in sync when making changes.
echo "Writing PREINIT script..."

# Clean up old postinit script if present
rm -f "${PERSIST_DIR}/hailo-postinit.sh"

cat > "${PERSIST_DIR}/hailo-preinit.sh" <<'PREINIT_EOF'
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

set -uo pipefail

log() {
    echo "[hailo-preinit] $*"
    logger -t hailo-preinit "$*" 2>/dev/null || true
}

# --- Find persistent config via glob ---
PERSIST_DIR=""
for d in /mnt/*/.config/hailo; do
    [ -d "$d" ] && PERSIST_DIR="$d" && break
done

if [ -z "$PERSIST_DIR" ]; then
    log "No persistent config found at /mnt/*/.config/hailo/, nothing to do"
    exit 0
fi

HAILO_RAW_BACKUP="${PERSIST_DIR}/hailo.raw"
SYSEXT_TARGET="/usr/share/truenas/sysext-extensions/hailo.raw"

if [ ! -f "$HAILO_RAW_BACKUP" ]; then
    log "No hailo.raw backup at ${HAILO_RAW_BACKUP}, nothing to do"
    exit 0
fi

# --- Compare checksums and reinstall if needed ---
NEED_COPY=true
if [ -f "$SYSEXT_TARGET" ]; then
    INSTALLED_SUM=$(sha256sum "$SYSEXT_TARGET" | awk '{print $1}')
    BACKUP_SUM=$(sha256sum "$HAILO_RAW_BACKUP" | awk '{print $1}')
    if [ "$INSTALLED_SUM" = "$BACKUP_SUM" ]; then
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
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=off "$USR_DATASET"
    fi

    log "Copying hailo.raw from backup..."
    if ! cp "$HAILO_RAW_BACKUP" "$SYSEXT_TARGET"; then
        log "ERROR: Failed to copy hailo.raw from backup"
        [ -n "$USR_DATASET" ] && zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        exit 1
    fi

    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET"
    fi
fi

# --- Always activate sysext (symlink is on tmpfs, gone after reboot) ---
log "Activating hailo sysext..."
mkdir -p /run/extensions
ln -sf "$SYSEXT_TARGET" /run/extensions/hailo.raw
systemd-sysext refresh
ldconfig

# --- Check kernel version matches the module in the sysext ---
HAILO_KO="/usr/lib/modules/$(uname -r)/extra/hailo_pci.ko"
if [ -f "$HAILO_KO" ]; then
    log "Loading Hailo module..."
    insmod "$HAILO_KO" || log "WARNING: insmod hailo_pci failed (device may not be present)"
else
    # Module path doesn't match running kernel — likely a TrueNAS update changed the kernel
    SYSEXT_KVER=$(ls /usr/lib/modules/ 2>/dev/null | grep -v "$(uname -r)" | head -1)
    if [ -n "$SYSEXT_KVER" ]; then
        log "ERROR: Kernel version mismatch — running $(uname -r) but sysext has module for ${SYSEXT_KVER}"
        log "ERROR: TrueNAS was likely updated. Download a new hailo.raw release matching $(uname -r)"
        log "ERROR: Visit https://github.com/scyto/truenas-hailo/releases"
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
PREINIT_EOF
chmod +x "${PERSIST_DIR}/hailo-preinit.sh"

# --- Register PREINIT script via midclt ---
PREINIT_SCRIPT="${PERSIST_DIR}/hailo-preinit.sh"
echo "Registering PREINIT script..."

# Find any existing hailo init script (postinit or preinit)
EXISTING_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get('command', '') or s.get('script', '')
        if 'hailo-preinit' in cmd or 'hailo-postinit' in cmd or '.config/hailo' in cmd:
            print(s['id'], end='')
            break
except Exception:
    pass
" 2>/dev/null)

if [ -n "$EXISTING_ID" ]; then
    echo "Hailo init script already registered (id: ${EXISTING_ID}), updating to PREINIT..."
    midclt call initshutdownscript.update "$EXISTING_ID" "{\"type\": \"COMMAND\", \"command\": \"${PREINIT_SCRIPT}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 30, \"comment\": \"Activate Hailo-8 sysext before apps start\"}" 2>/dev/null \
        || echo "WARNING: Failed to update init script"
else
    midclt call initshutdownscript.create "{\"type\": \"COMMAND\", \"command\": \"${PREINIT_SCRIPT}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 30, \"comment\": \"Activate Hailo-8 sysext before apps start\"}" 2>/dev/null \
        || echo "WARNING: Failed to register PREINIT script"
    echo "PREINIT script registered"
fi

echo ""
echo "=== Persistence setup complete ==="
echo ""
echo "Persistent config: ${PERSIST_DIR}/"
echo "  hailo.raw                — sysext backup (includes firmware)"
echo "  .hailo-driver-version    — HailoRT version (informational)"
echo "  hailo-preinit.sh         — runs before apps start (registered as PREINIT)"
echo ""
echo "The Hailo-8 driver will survive TrueNAS updates and reboots."
