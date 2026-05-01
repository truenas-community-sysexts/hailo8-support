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
#    or: sudo ./install.sh --check          (probe an existing install)
#    or: sudo ./install.sh --dry-run        (validate without modifying)
# See --help for the full option list.

set -euo pipefail

# hailo_init_script_lookup
#
# Locate any registered TrueNAS init script related to this fork (matches
# "hailo-preinit", "hailo-postinit", or ".config/hailo" in the command/script
# field). Used by --check, by registration to find an existing entry to update,
# and by restore.sh to find an entry to delete — match logic must stay aligned
# across all three. Prints:
#   `<id>|<when>|<enabled>`  if found (when=PREINIT/POSTINIT/...; enabled=True/False)
#   ``                       (empty) if no matching script is registered
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

# do_check: read-only probe of an existing install. Exits 0 if all checks
# pass (warnings allowed), 1 if any check fails. Used by --check.
do_check() {
    local pass=0 warn=0 fail=0
    local mark_ok="✓" mark_warn="⚠" mark_fail="✗"
    local -a status_lines=()
    local -a hint_lines=()

    record_pass() { status_lines+=("  ${mark_ok} $1"); pass=$((pass+1)); }
    record_warn() {
        status_lines+=("  ${mark_warn} $1"); warn=$((warn+1))
        [ -n "${2:-}" ] && hint_lines+=("    → $2")
    }
    record_fail() {
        status_lines+=("  ${mark_fail} $1"); fail=$((fail+1))
        [ -n "${2:-}" ] && hint_lines+=("    → $2")
    }

    echo "=== Hailo-8 install status ==="
    echo ""

    # 1. PCIe device node
    if [ -e /dev/hailo0 ]; then
        record_pass "Device /dev/hailo0 present"
    else
        record_fail "Device /dev/hailo0 not present" \
            "is the Hailo-8 PCIe card seated, and was the system rebooted after install?"
    fi

    # 2. Kernel module loaded
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx hailo_pci; then
        record_pass "Kernel module hailo_pci loaded"
    else
        record_fail "Kernel module hailo_pci not loaded" \
            "run 'sudo insmod /usr/lib/modules/\$(uname -r)/extra/hailo_pci.ko' or re-run install.sh"
    fi

    # 3. Sysext file present on disk
    if [ -f "$HAILO_RAW" ]; then
        record_pass "Sysext present at ${HAILO_RAW}"
    else
        record_fail "Sysext missing at ${HAILO_RAW}" "re-run install.sh"
    fi

    # 4. Sysext merged into /usr
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx hailo; then
        record_pass "Sysext merged into /usr"
    else
        record_warn "Sysext not currently merged" \
            "the PREINIT script merges it on boot; check 'systemctl status systemd-sysext'"
    fi

    # 5. Persistent config dir
    local persist_dir=""
    for d in /mnt/*/.config/hailo; do
        [ -d "$d" ] && persist_dir="$d" && break
    done
    if [ -n "$persist_dir" ]; then
        record_pass "Persistent config at ${persist_dir}"
    else
        record_fail "No persistent config under /mnt/*/.config/hailo/" \
            "re-run install.sh with --pool=NAME or --persist-path=PATH"
    fi

    # 6. Backup hailo.raw on persistent pool
    if [ -n "$persist_dir" ] && [ -f "${persist_dir}/hailo.raw" ]; then
        record_pass "Backup ${persist_dir}/hailo.raw present"
    elif [ -n "$persist_dir" ]; then
        record_fail "Backup hailo.raw missing in ${persist_dir}" "re-run install.sh"
    fi

    # 7. PREINIT script on disk
    if [ -n "$persist_dir" ] && [ -x "${persist_dir}/hailo-preinit.sh" ]; then
        record_pass "PREINIT script ${persist_dir}/hailo-preinit.sh present and executable"
    elif [ -n "$persist_dir" ]; then
        record_fail "PREINIT script missing or not executable in ${persist_dir}" "re-run install.sh"
    fi

    # 8. PREINIT registered with TrueNAS middleware (read-only midclt query)
    if command -v midclt >/dev/null 2>&1; then
        local lookup script_when script_enabled
        lookup=$(hailo_init_script_lookup)
        case "$lookup" in
            error)
                record_warn "Could not query TrueNAS middleware" \
                    "run with sudo on TrueNAS SCALE"
                ;;
            "")
                record_fail "No init script registered for hailo" "re-run install.sh"
                ;;
            *)
                IFS='|' read -r _ script_when script_enabled <<<"$lookup"
                if [ "$script_when" = "PREINIT" ] && [ "$script_enabled" = "True" ]; then
                    record_pass "PREINIT script registered with TrueNAS middleware (PREINIT, enabled)"
                else
                    record_warn "Init script registered but not as enabled PREINIT" \
                        "re-run install.sh to fix"
                fi
                ;;
        esac
    else
        record_warn "midclt not available — skipping middleware check" \
            "this script must run on TrueNAS SCALE"
    fi

    # 9. Kernel module path matches running kernel
    local running_kver hailo_ko
    running_kver=$(uname -r)
    hailo_ko="/usr/lib/modules/${running_kver}/extra/hailo_pci.ko"
    if [ -f "$hailo_ko" ]; then
        record_pass "Kernel module path matches running kernel ${running_kver}"
    else
        record_fail "No hailo_pci.ko for running kernel ${running_kver}" \
            "see docs/troubleshooting.md (kernel-mismatch recovery)"
    fi

    # 10. PREINIT script result on last boot.
    # hailo-preinit.sh logs via `logger -t hailo-preinit`, so journalctl can
    # filter by tag. The script ends with a "Done" sentinel on success; any
    # ERROR: line in the same boot indicates a failure path was hit.
    if ! command -v journalctl >/dev/null 2>&1; then
        record_fail "journalctl not available — cannot read PREINIT result" \
            "this script must run on TrueNAS SCALE"
    else
        local preinit_log preinit_last
        preinit_log=$(journalctl -b -t hailo-preinit --no-pager -o cat 2>/dev/null || true)
        if [ -z "$preinit_log" ]; then
            record_warn "No hailo-preinit entries this boot" \
                "PREINIT may not be registered yet — reboot after install, or re-run install.sh"
        elif printf '%s' "$preinit_log" | grep -q '^ERROR:'; then
            preinit_last=$(printf '%s' "$preinit_log" | grep '^ERROR:' | head -1)
            record_fail "PREINIT logged an error this boot: ${preinit_last}" \
                "see docs/troubleshooting.md and full log: journalctl -b -t hailo-preinit"
        else
            preinit_last=$(printf '%s' "$preinit_log" | tail -1)
            if [ "$preinit_last" = "Done" ]; then
                record_pass "PREINIT completed successfully this boot"
            else
                record_warn "PREINIT ran but did not log the Done sentinel (last: ${preinit_last})" \
                    "review full log: journalctl -b -t hailo-preinit"
            fi
        fi
    fi

    printf '%s\n' "${status_lines[@]}"
    echo ""
    if [ "${#hint_lines[@]}" -gt 0 ]; then
        printf '%s\n' "${hint_lines[@]}"
        echo ""
    fi
    printf 'Summary: %d ok, %d warn, %d fail\n' "$pass" "$warn" "$fail"

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# if_real: run a command unless --dry-run is set, in which case print what
# would have been run. For redirections and heredocs, gate the entire block
# manually with `if [ "$DRY_RUN" = "1" ]; then ... else ... fi` since the
# shell evaluates redirections before the command runs.
if_real() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] would: %s\n' "$*"
    else
        "$@"
    fi
}

# REPO can be overridden via --repo=OWNER/NAME or HAILO_REPO env var.
REPO="${HAILO_REPO:-scyto/truenas-hailo}"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
HAILO_RAW="${SYSEXT_DIR}/hailo.raw"

# --- Parse CLI arguments ---
LOCAL_RAW=""
POOL_NAME=""
PERSIST_PATH=""
CHECK_MODE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --repo=*)
            REPO="${arg#*=}"
            [ -n "$REPO" ] || { echo "ERROR: --repo= requires a non-empty value (e.g., --repo=owner/name)" >&2; exit 2; }
            ;;
        --pool=*)
            POOL_NAME="${arg#*=}"
            [ -n "$POOL_NAME" ] || { echo "ERROR: --pool= requires a non-empty value" >&2; exit 2; }
            ;;
        --persist-path=*)
            PERSIST_PATH="${arg#*=}"
            [ -n "$PERSIST_PATH" ] || { echo "ERROR: --persist-path= requires a non-empty value" >&2; exit 2; }
            ;;
        --check) CHECK_MODE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-hailo.raw]"
            echo ""
            echo "Options:"
            echo "  --repo=OWNER/NAME        GitHub repo to download release from (default: scyto/truenas-hailo)"
            echo "                           Can also be set via HAILO_REPO env var."
            echo "  --pool=NAME              ZFS pool for persistent config (e.g., fast)"
            echo "  --persist-path=PATH      Exact path for persistent config"
            echo "  --check                  Probe an existing install (read-only) and report status"
            echo "  --dry-run                Validate everything (downloads, checksums, network) without modifying the system"
            echo "  --help                   Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo ./install.sh --pool=fast"
            echo "  sudo ./install.sh --check"
            echo "  sudo ./install.sh --dry-run"
            echo "  sudo ./install.sh /tmp/hailo-input.raw   # any path other than /tmp/hailo.raw (staging)"
            echo "  curl -fsSL <url>/install.sh | sudo bash"
            exit 0
            ;;
        *)
            # A `curl | sudo bash` user who typos `--pol=fast` or `/tmp/typ.raw`
            # silently gets auto-detect / a release download — they think their
            # flag took effect when it didn't. Refuse rather than guess.
            if [ -f "$arg" ]; then
                LOCAL_RAW="$arg"
            elif [[ "$arg" == -* ]]; then
                echo "ERROR: unknown option: $arg (see --help)" >&2
                exit 2
            else
                echo "ERROR: positional argument is not an existing file: $arg" >&2
                echo "  Pass --help for usage." >&2
                exit 2
            fi
            ;;
    esac
done

if [ "$CHECK_MODE" = "1" ] && [ "$DRY_RUN" = "1" ]; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2
    exit 2
fi

if [ "$CHECK_MODE" = "1" ]; then
    do_check
    exit $?
fi

# USR_WAS_WRITABLE: 1 while we have ${USR_DATASET}'s readonly=off and
# haven't restored it yet. The cleanup trap re-asserts readonly=on so
# any failure path between off and on (cp errors, SIGINT/SIGTERM) does
# not leave /usr writable until reboot.
USR_WAS_WRITABLE=0

cleanup() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "${USR_DATASET:-}" ] && [ "$DRY_RUN" != "1" ]; then
        zfs set readonly=on "${USR_DATASET}" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    rm -f /tmp/hailo.raw /tmp/hailo.raw.sha256 /tmp/hailo8_fw.bin /tmp/hailo-preinit.sh
    rm -rf /tmp/hailo-sysext-unpack
}
trap cleanup EXIT INT TERM

# If a local path is provided, use it; otherwise download from GitHub releases
if [ -n "$LOCAL_RAW" ]; then
    # Reject input path == /tmp/hailo.raw (the installer's staging path):
    # cp would refuse with "are the same file" and the EXIT trap (which
    # always fires) would then rm -f /tmp/hailo.raw, deleting the user's
    # input. Detect and refuse rather than risk the data loss; user can
    # copy/move and re-run.
    LOCAL_REAL=$(realpath "$LOCAL_RAW" 2>/dev/null || echo "$LOCAL_RAW")
    STAGE_REAL=$(realpath -m /tmp/hailo.raw 2>/dev/null || echo /tmp/hailo.raw)
    if [ "$LOCAL_REAL" = "$STAGE_REAL" ]; then
        echo "ERROR: input file is at /tmp/hailo.raw, which collides with the installer's staging path." >&2
        echo "  Move or copy it to a different path (e.g. /tmp/hailo-input.raw) and re-run." >&2
        exit 2
    fi
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
    RELEASE_TAG=$(curl -sf --max-time 30 "https://api.github.com/repos/${REPO}/releases" \
        | python3 -c "
import sys, json
try:
    releases = json.load(sys.stdin)
    version = '${VERSION}'
    # Anchor the match: v<version>-* prevents 25.10.3 from matching 25.10.3.1.
    prefix = f'v{version}-'
    matches = [r for r in releases if r.get('tag_name', '').startswith(prefix)]
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
        curl -sf --max-time 30 "https://api.github.com/repos/${REPO}/releases" \
            | python3 -c "import sys,json; [print(f'  {r[\"tag_name\"]}') for r in json.load(sys.stdin)]"
        exit 1
    fi

    echo "Found release: ${RELEASE_TAG}"

    # Download hailo.raw and checksum
    BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
    echo "Downloading hailo.raw..."
    curl -fSL --max-time 600 "${BASE_URL}/hailo.raw" -o /tmp/hailo.raw || { echo "ERROR: Failed to download hailo.raw"; exit 1; }
    curl -fSL --max-time 600 "${BASE_URL}/hailo.raw.sha256" -o /tmp/hailo.raw.sha256 || { echo "ERROR: Failed to download checksum"; exit 1; }

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

# Fetch tracked-versions.json once and reuse for both HAILO_VERSION fallback
# and firmware-sha256 verification below. Two fetches in close succession
# would open a small TOCTOU window where a push between them could leave
# version and sha256 inconsistent.
TRACKED_VERSIONS_JSON=$(curl -sf --max-time 30 \
    "https://raw.githubusercontent.com/${REPO}/main/.github/tracked-versions.json" 2>/dev/null) || TRACKED_VERSIONS_JSON=""

# Determine HailoRT version from release tag or the repo's tracked-versions
# state file. The release tag is the primary source (format v<truenas>-hailo<driver>);
# the JSON fallback handles tag-format drift.
HAILO_VERSION=""
if [ -n "${RELEASE_TAG:-}" ]; then
    # Extract version from tag like v25.10.2.1-hailo4.20.0
    HAILO_VERSION=$(echo "$RELEASE_TAG" | sed -n 's/.*hailo\([0-9.]*\)$/\1/p')
fi
if [ -z "$HAILO_VERSION" ] && [ -n "$TRACKED_VERSIONS_JSON" ]; then
    HAILO_VERSION=$(printf '%s' "$TRACKED_VERSIONS_JSON" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['hailo']['driver'])" 2>/dev/null) || true
fi
if [ -z "$HAILO_VERSION" ]; then
    echo "ERROR: Could not determine HailoRT version from release tag or repo state."
    echo "  Ensure the release tag matches v<truenas>-hailo<driver> format,"
    echo "  or that ${REPO} has .github/tracked-versions.json on the main branch."
    exit 1
fi

echo "HailoRT version: ${HAILO_VERSION}"
FW_URL="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/${HAILO_VERSION}/FW/hailo8_fw.${HAILO_VERSION}.bin"

echo "Downloading firmware from Hailo..."
if ! curl -fSL --max-time 600 "$FW_URL" -o /tmp/hailo8_fw.bin; then
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

# --- Verify firmware against published sha256 ---
# tracked-versions.json records the sha256 of the firmware that matches the
# tracked HailoRT driver. Reuses the JSON fetched earlier (same snapshot
# used to resolve HAILO_VERSION) so the version and sha256 always come from
# the same point-in-time view of the source repo.
echo "Verifying firmware sha256..."
LOCAL_FW_SHA=$(sha256sum /tmp/hailo8_fw.bin | awk '{print $1}')
echo "  local sha256:  ${LOCAL_FW_SHA}"

PUBLISHED_FW_SHA=$(printf '%s' "$TRACKED_VERSIONS_JSON" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('hailo', {}).get('firmware_sha256', '')
    print(v, end='')
except Exception:
    pass
" 2>/dev/null) || PUBLISHED_FW_SHA=""

if [ -z "$PUBLISHED_FW_SHA" ]; then
    echo "ERROR: Could not fetch hailo.firmware_sha256 from ${REPO}/.github/tracked-versions.json" >&2
    echo "  Refusing to install unverified firmware. Check that the field exists in the source repo's tracked-versions.json." >&2
    rm -f /tmp/hailo8_fw.bin
    exit 1
fi
if ! printf '%s' "$PUBLISHED_FW_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    echo "ERROR: Published firmware_sha256 is not a 64-char hex string: '${PUBLISHED_FW_SHA}'" >&2
    rm -f /tmp/hailo8_fw.bin
    exit 1
fi
echo "  published:     ${PUBLISHED_FW_SHA}"

if [ "$LOCAL_FW_SHA" != "$PUBLISHED_FW_SHA" ]; then
    echo "ERROR: Firmware sha256 mismatch — refusing to install" >&2
    echo "  expected: ${PUBLISHED_FW_SHA}" >&2
    echo "  got:      ${LOCAL_FW_SHA}" >&2
    echo "  This usually means the Hailo S3 bucket has a different version" >&2
    echo "  than tracked-versions.json expected. Re-check the tracked HailoRT" >&2
    echo "  driver version, or open an issue on ${REPO}." >&2
    rm -f /tmp/hailo8_fw.bin
    exit 1
fi
echo "Firmware sha256 OK"

# --- Inject firmware into hailo.raw squashfs ---
echo "Injecting firmware into hailo.raw..."
if command -v unsquashfs &>/dev/null && command -v mksquashfs &>/dev/null; then
    # The cleanup trap normally clears this, but a SIGKILL'd or panic'd
    # prior run can leave it behind — unsquashfs -d refuses to overwrite.
    rm -rf /tmp/hailo-sysext-unpack
    unsquashfs -d /tmp/hailo-sysext-unpack /tmp/hailo.raw
    mkdir -p /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo
    cp /tmp/hailo8_fw.bin /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo/hailo8_fw.bin
    # Pull the PREINIT script out of the unpacked sysext while we have it
    # mounted. We need it later (~PERSIST_DIR setup), but the sysext is the
    # source of truth — whatever hailo.raw the user installs ships with the
    # matching preinit. Older releases (pre-bundling) won't have it; refuse
    # rather than silently ship without persistence.
    BUNDLED_PREINIT="/tmp/hailo-sysext-unpack/usr/lib/hailo/hailo-preinit.sh"
    if [ ! -f "$BUNDLED_PREINIT" ]; then
        echo "ERROR: hailo-preinit.sh not found in sysext at /usr/lib/hailo/hailo-preinit.sh" >&2
        echo "  This hailo.raw was built before the preinit script was bundled in." >&2
        echo "  Re-fetch a current release: https://github.com/${REPO}/releases/latest" >&2
        exit 1
    fi
    cp "$BUNDLED_PREINIT" /tmp/hailo-preinit.sh
    chmod +x /tmp/hailo-preinit.sh
    mksquashfs /tmp/hailo-sysext-unpack /tmp/hailo.raw -noappend -comp zstd -all-root
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
if_real rm -f /run/extensions/hailo.raw
if_real systemd-sysext unmerge 2>/dev/null || true

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null) || { echo "ERROR: Failed to find ZFS dataset for /usr"; exit 1; }
[ -z "$USR_DATASET" ] && { echo "ERROR: ZFS dataset for /usr is empty"; exit 1; }
echo "Setting ${USR_DATASET} to writable..."
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: zfs set readonly=off ${USR_DATASET}"
else
    zfs set readonly=off "${USR_DATASET}" || { echo "ERROR: Failed to make ${USR_DATASET} writable"; exit 1; }
    USR_WAS_WRITABLE=1
fi

# Install new hailo.raw (backup is on persistent pool, no need for .bak).
# If cp fails, the cleanup trap re-asserts readonly=on so we never
# leave /usr writable on the failure path.
echo "Installing new hailo.raw..."
if_real cp /tmp/hailo.raw "${HAILO_RAW}"

# Restore read-only
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: zfs set readonly=on ${USR_DATASET}"
else
    zfs set readonly=on "${USR_DATASET}"
    USR_WAS_WRITABLE=0
fi

# Activate sysext via symlink + refresh (TrueNAS middleware pattern)
echo "Activating hailo sysext..."
if_real mkdir -p /run/extensions
if_real ln -sf "${HAILO_RAW}" /run/extensions/hailo.raw
if_real systemd-sysext refresh
if_real ldconfig

# Load the kernel module (use insmod directly — /lib/modules is read-only on TrueNAS
# so depmod can't update module deps, and modprobe can't find modules without it)
echo "Loading Hailo kernel module..."
HAILO_KO="/usr/lib/modules/$(uname -r)/extra/hailo_pci.ko"
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: insmod ${HAILO_KO} (if present)"
elif [ -f "$HAILO_KO" ]; then
    insmod "$HAILO_KO" || echo "WARNING: insmod hailo_pci failed (device may not be present)"
else
    echo "WARNING: hailo_pci.ko not found at ${HAILO_KO}"
fi

# Reload udev rules from sysext so /dev/hailo0 gets correct permissions
echo "Reloading udev rules..."
if_real udevadm control --reload-rules 2>/dev/null || true
if [ -e /dev/hailo0 ]; then
    if_real udevadm trigger /dev/hailo0 2>/dev/null || true
fi

echo ""
echo "=== Installation complete ==="
echo ""

# Verify
if [ -e /dev/hailo0 ]; then
    echo "Device /dev/hailo0 detected!"
    if command -v hailortcli &>/dev/null; then
        echo "Firmware identification:"
        hailortcli fw-control identify 2>/dev/null || echo "(device query failed — may need reboot)"
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
        # Hard fail rather than exit 0: persistence isn't optional. Without
        # it, the next reboot wipes the sysext (no PREINIT registered, no
        # backup on a persistent pool) and the Hailo device disappears. The
        # `curl | sudo bash` flow makes a printed warning easy to miss —
        # especially after the earlier "Installation complete" line.
        echo "ERROR: No ZFS pool found (excluding boot-pool). Cannot set up persistence." >&2
        echo "  The sysext is loaded for this session but will NOT survive a reboot." >&2
        echo "  Re-run with one of:" >&2
        echo "    sudo ./install.sh --pool=<name>" >&2
        echo "    sudo ./install.sh --persist-path=/mnt/<pool>/<path>" >&2
        exit 1
    fi
fi

echo "Persistent config directory: ${PERSIST_DIR}"
if_real mkdir -p "$PERSIST_DIR"

# --- Backup hailo.raw (with firmware inside) to persistent storage ---
echo "Backing up hailo.raw to persistent storage..."
if_real cp /tmp/hailo.raw "${PERSIST_DIR}/hailo.raw"

# Save HailoRT version for reference
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write \$HAILO_VERSION (${HAILO_VERSION}) to ${PERSIST_DIR}/.hailo-driver-version"
else
    echo -n "$HAILO_VERSION" > "${PERSIST_DIR}/.hailo-driver-version"
fi

# Save source repo so the boot-time PREINIT script can point users at the right
# releases page when a kernel mismatch is detected.
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write \$REPO (${REPO}) to ${PERSIST_DIR}/.hailo-repo"
else
    echo -n "$REPO" > "${PERSIST_DIR}/.hailo-repo"
fi

# --- Install PREINIT script to persistent storage ---
# Source is /tmp/hailo-preinit.sh, which we extracted from the unsquashed
# sysext earlier (see "Inject firmware" block). Bundling the script in the
# sysext means the hailo.raw release artifact is self-contained — whatever
# .raw the user installs ships with the matching preinit.
echo "Installing PREINIT script..."

# Clean up old postinit script if present
if_real rm -f "${PERSIST_DIR}/hailo-postinit.sh"

if_real cp /tmp/hailo-preinit.sh "${PERSIST_DIR}/hailo-preinit.sh"
if_real chmod +x "${PERSIST_DIR}/hailo-preinit.sh"

# --- Register PREINIT script via midclt ---
PREINIT_SCRIPT="${PERSIST_DIR}/hailo-preinit.sh"
echo "Registering PREINIT script..."

# Find any existing hailo init script (postinit or preinit). A midclt
# lookup error is NOT the same as not-found: midclt records aren't keyed
# by command, so falling through to create on a transient query failure
# can produce a duplicate registration that restore.sh's first-match
# cleanup won't fully undo. Refuse rather than guess.
EXISTING_LOOKUP=$(hailo_init_script_lookup)
if [ "$EXISTING_LOOKUP" = "error" ]; then
    echo "ERROR: Could not query TrueNAS middleware to check for existing init scripts." >&2
    echo "  Refusing to register without a clean lookup — risks duplicate PREINIT entries." >&2
    echo "  Run 'midclt call initshutdownscript.query' to confirm middleware health, then re-run." >&2
    exit 1
fi
EXISTING_ID="${EXISTING_LOOKUP%%|*}"

# Build the payload via python3 -> json.dumps so PREINIT_SCRIPT is escaped
# correctly even if the path ever grows characters that are special to JSON.
PREINIT_PAYLOAD=$(PREINIT_SCRIPT="$PREINIT_SCRIPT" python3 -c '
import json, os
print(json.dumps({
    "type": "COMMAND",
    "command": os.environ["PREINIT_SCRIPT"],
    "when": "PREINIT",
    "enabled": True,
    "timeout": 30,
    "comment": "Activate Hailo-8 sysext before apps start",
}))
')

if [ -n "$EXISTING_ID" ]; then
    echo "Hailo init script already registered (id: ${EXISTING_ID}), updating to PREINIT..."
    if ! if_real midclt call initshutdownscript.update "$EXISTING_ID" "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to update init script (id: ${EXISTING_ID})." >&2
        echo "ERROR: Without a registered PREINIT script the sysext will NOT survive a reboot." >&2
        echo "ERROR: Check 'midclt call initshutdownscript.query' and re-run the installer." >&2
        exit 1
    fi
else
    if ! if_real midclt call initshutdownscript.create "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to register PREINIT script via midclt." >&2
        echo "ERROR: Without a registered PREINIT script the sysext will NOT survive a reboot." >&2
        echo "ERROR: Check that the TrueNAS middleware is reachable (midclt call core.ping) and re-run." >&2
        exit 1
    fi
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

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== Dry-run complete ==="
    echo "No changes were made to the system."
    echo ""
    echo "Would have installed:"
    echo "  Sysext target:     ${HAILO_RAW}"
    echo "  Persistent dir:    ${PERSIST_DIR}"
    echo "  HailoRT version:   ${HAILO_VERSION}"
    [ -n "${RELEASE_TAG:-}" ] && echo "  Release tag:       ${RELEASE_TAG}"
fi
