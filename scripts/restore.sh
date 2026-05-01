#!/usr/bin/env bash
# Restores the original state by removing hailo.raw sysext.
# Run this to completely remove the Hailo-8 driver extension.

set -euo pipefail

# hailo_init_script_lookup
#
# Locate any registered TrueNAS init script related to this fork (matches
# "hailo-preinit", "hailo-postinit", or ".config/hailo" in the command/script
# field). Match logic must stay aligned with install.sh's copy of this
# function — install.sh uses it for --check probing and for finding an
# existing entry to update; restore.sh uses it for finding an entry to
# delete. Prints:
#   `<id>|<when>|<enabled>`  if found
#   ``                       (empty) if not registered
#   `error`                  if midclt is unreachable / response unparseable
# Always exits 0; callers branch on the printed token.
hailo_init_script_lookup() {
    local result
    # Use %-formatting (not f-strings): the surrounding bash uses single
    # quotes for the python source so we can't put `'` inside the python
    # body, and an f-string with `"` keys would need `\"` escapes that
    # don't parse inside f-string `{}` blocks.
    result=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c '
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get("command", "") or s.get("script", "")
        if "hailo-preinit" in cmd or "hailo-postinit" in cmd or ".config/hailo" in cmd:
            print("%s|%s|%s" % (s["id"], s.get("when", ""), s.get("enabled", False)), end="")
            sys.exit(0)
except Exception:
    print("error", end="")
' 2>/dev/null) || result=error
    printf '%s' "$result"
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

# Unload module if present
if lsmod 2>/dev/null | awk '{print $1}' | grep -qx hailo_pci; then
    echo "Unloading hailo_pci module..."
    rmmod hailo_pci || echo "WARNING: Failed to unload hailo_pci"
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
