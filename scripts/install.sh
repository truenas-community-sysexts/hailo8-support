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

    # 3. Activation symlink present and resolves to an image. It lives on tmpfs
    # (/run/extensions), so the PREINIT script recreates it on every boot; a
    # missing symlink is a warning, not a hard failure.
    if [ -L /run/extensions/hailo.raw ] && [ -f /run/extensions/hailo.raw ]; then
        record_pass "Activation symlink /run/extensions/hailo.raw resolves to an image"
    else
        record_warn "Activation symlink /run/extensions/hailo.raw missing or dangling" \
            "the PREINIT script recreates it on boot; reboot or re-run install.sh"
    fi

    # 4. Sysext merged into /usr
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx hailo; then
        record_pass "Sysext merged into /usr"
    else
        record_warn "Sysext not currently merged" \
            "the PREINIT script merges it on boot; check 'systemctl status systemd-sysext'"
    fi

    # 5. Persistent config dir (read-only probe: no prompt, no auto-select)
    local persist_dir=""
    if resolve_persist_dir probe; then
        persist_dir="$PERSIST_DIR"
        record_pass "Persistent config at ${persist_dir}"
    else
        record_fail "No persistent config resolved" \
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

# hailo_init_script_lookup
#
# Locate any registered TrueNAS init script related to this fork (matches
# "hailo-preinit", "hailo-postinit", or ".config/hailo" in the command/script
# field). Used for --check probing and for finding an existing entry to
# update. restore.sh carries an identical copy for deregistration; the
# helper is inlined in both because a `curl | bash` run has no sibling file
# to source, and fetching one at run time made every install depend on what
# the Latest release happened to ship. tests/test_script_helpers.py keeps
# the two copies identical.
#
# Prints:
#   <id>|<when>|<enabled>  if found (when=PREINIT/POSTINIT/...; enabled=True/False)
#   (empty)                if no matching script is registered
#   error                  if midclt is unreachable / response unparseable
#
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

# resolve_persist_dir — determine where persistent config lives.
# Priority: --persist-path > --pool > existing config dir > only-data-pool
#         > interactive prompt (multi-pool) > error (no tty + ambiguous)
# Sets PERSIST_DIR on success; prints to stderr and returns 1 on failure.
#
# Call with "probe" (used by --check) for a read-only resolution: it never
# prompts and never auto-selects a pool whose config dir doesn't exist yet,
# so a diagnostic can't report a PASS for storage that was never set up.
resolve_persist_dir() {
    PERSIST_DIR=""
    local probe="${1:-}"
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then
        PERSIST_DIR="$PERSIST_PATH"
        return 0
    fi
    if [ -n "${POOL_NAME:-}" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/hailo"
        return 0
    fi

    shopt -s nullglob
    for d in /mnt/*/.config/hailo; do
        [ -d "$d" ] && existing+=("$d")
    done
    shopt -u nullglob

    if [ "$probe" = "probe" ]; then
        if [ "${#existing[@]}" -ge 1 ]; then
            PERSIST_DIR="${existing[0]}"
            return 0
        fi
        return 1
    fi

    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"
        echo "Re-using existing config: $PERSIST_DIR"
        return 0
    fi

    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: No ZFS pool found (excluding boot-pool). Cannot set up persistence." >&2
        echo "  Re-run with --pool=<name> or --persist-path=/mnt/<pool>/<path>" >&2
        return 1
    fi

    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/hailo"
        echo "Auto-selected pool: ${pools[0]} → $PERSIST_DIR"
        return 0
    fi

    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing hailo configs on multiple pools:"
        choices=("${existing[@]}")
    else
        header="Multiple data pools available (no existing config):"
        for p in "${pools[@]}"; do
            choices+=("/mnt/${p}/.config/hailo")
        done
    fi

    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "  No controlling terminal. Pass --pool=<name> or --persist-path=<path>." >&2
        return 1
    fi

    echo "$header"
    for i in "${!choices[@]}"; do
        echo "  [$((i+1))] ${choices[$i]}"
    done
    while true; do
        printf 'Pick one (1-%d): ' "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"
            echo "Selected: $PERSIST_DIR"
            return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}

# REPO can be overridden via --repo=OWNER/NAME or HAILO_REPO env var.
REPO="${HAILO_REPO:-truenas-community-sysexts/hailo8-support}"
# HAILO_RAW (the sysext image we activate) lives on the data pool and is set
# to "${PERSIST_DIR}/hailo.raw" once the persistent pool is resolved below.
HAILO_RAW=""

# --- Parse CLI arguments ---
LOCAL_RAW=""
POOL_NAME=""
PERSIST_PATH=""
CHECK_MODE=0
DRY_RUN=0
# Override for --local-raw users (no release to fetch firmware.sha256 from).
# Set to a 64-char hex sha256 via --expected-firmware-sha=<hex>.
EXPECTED_FW_SHA=""
# Override for --local-raw users when the local sysext was built against a
# specific HailoRT version. Set via --firmware-version=<x.y.z>.
LOCAL_FW_VERSION=""

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
        --expected-firmware-sha=*)
            EXPECTED_FW_SHA="${arg#*=}"
            if ! printf '%s' "$EXPECTED_FW_SHA" | grep -qE '^[0-9a-f]{64}$'; then
                echo "ERROR: --expected-firmware-sha= requires a 64-char lowercase hex sha256" >&2
                exit 2
            fi
            ;;
        --firmware-version=*)
            LOCAL_FW_VERSION="${arg#*=}"
            if ! printf '%s' "$LOCAL_FW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "ERROR: --firmware-version= requires X.Y.Z (e.g., 4.21.0)" >&2
                exit 2
            fi
            ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-hailo.raw]"
            echo ""
            echo "Options:"
            echo "  --repo=OWNER/NAME             GitHub repo to download release from (default: truenas-community-sysexts/hailo8-support)"
            echo "                                Can also be set via HAILO_REPO env var."
            echo "  --pool=NAME                   ZFS pool for persistent config (e.g., fast)"
            echo "  --persist-path=PATH           Exact path for persistent config"
            echo "  --check                       Probe an existing install (read-only) and report status"
            echo "  --dry-run                     Validate everything (downloads, checksums, network) without modifying the system"
            echo "  --firmware-version=X.Y.Z      [--local-raw only] HailoRT firmware version to download"
            echo "  --expected-firmware-sha=HEX   [--local-raw only] expected sha256 of the firmware (64 hex chars)"
            echo "  --help                        Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo ./install.sh --pool=fast"
            echo "  sudo ./install.sh --check"
            echo "  sudo ./install.sh --dry-run"
            echo "  sudo ./install.sh /tmp/hailo-input.raw --firmware-version=4.21.0 --expected-firmware-sha=2a5c94..."
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

# Every mode past --help touches privileged state: zfs readonly toggles,
# writes under /usr, midclt, insmod. Fail fast with a clear message rather
# than partway through after a download, firmware fetch, and unsquash.
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root (use sudo)" >&2
    exit 1
fi

# Persistence only works if --persist-path is the exact location the
# boot-time PREINIT script scans: /mnt/<pool>/.config/hailo, a single pool
# component under /mnt. hailo-preinit.sh re-derives the dir by globbing
# /mnt/*/.config/hailo and reads nothing else, so any other path silently
# breaks persistence after the next reboot or TrueNAS update:
#   - tmpfs (/tmp, /run): backup and script gone on the next reboot
#   - an OS dir (/usr, /etc, /var, /data, /): wiped on the next update
#   - a real pool but wrong/deeper subdir (/mnt/tank/foo): the glob misses it
# Anchored regex (not a case glob, whose * would span /) enforces a single
# pool component. --pool resolves to this shape automatically.
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/hailo/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/hailo (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT script only scans /mnt/*/.config/hailo for the backup," >&2
        echo "  so any other location silently breaks persistence after a reboot or update." >&2
        echo "  Pass --pool=<name> instead (it resolves to /mnt/<name>/.config/hailo)." >&2
        exit 2
    fi
fi

# The project moved from scyto/truenas-hailo to truenas-community-sysexts/hailo8-support.
# Catch the old slug if it arrives via --repo=, HAILO_REPO env, or stale docs/configs,
# and redirect transparently rather than 404 on releases lookup.
if [ "$REPO" = "scyto/truenas-hailo" ]; then
    echo "Note: 'scyto/truenas-hailo' has moved; using 'truenas-community-sysexts/hailo8-support'."
    REPO="truenas-community-sysexts/hailo8-support"
fi

if [ "$CHECK_MODE" = "1" ]; then
    do_check
    exit $?
fi

WORK_DIR=$(mktemp -d /tmp/hailo-install.XXXXXXXXXX)

cleanup() {
    [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# If a local path is provided, use it; otherwise download from GitHub releases
if [ -n "$LOCAL_RAW" ]; then
    # Reject input path == staging path: cp would refuse with "are the same
    # file" and the EXIT trap would then rm -rf the work dir, deleting the
    # user's input. Detect and refuse rather than risk data loss.
    LOCAL_REAL=$(realpath "$LOCAL_RAW" 2>/dev/null || echo "$LOCAL_RAW")
    STAGE_REAL=$(realpath -m "${WORK_DIR}/hailo.raw" 2>/dev/null || echo "${WORK_DIR}/hailo.raw")
    if [ "$LOCAL_REAL" = "$STAGE_REAL" ]; then
        echo "ERROR: input file collides with the installer's staging path." >&2
        echo "  Move or copy it to a different path and re-run." >&2
        exit 2
    fi
    echo "Using local hailo.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" "${WORK_DIR}/hailo.raw"
else
    # Detect TrueNAS version: the version string decides the release channel
    # (stable vs preview). It is never inferred from the kernel number.
    VERSION=$(midclt call system.info | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['version'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
") || { echo "ERROR: Failed to detect TrueNAS version"; exit 1; }
    [ -z "$VERSION" ] && { echo "ERROR: TrueNAS version is empty"; exit 1; }

    # The running kernel is the match key: kernel modules bind to the exact
    # kernel string, and many TrueNAS versions share one kernel, so the right
    # release is the one built for this kernel, whichever TrueNAS version
    # produced it.
    KVER=$(uname -r)
    [ -z "$KVER" ] && { echo "ERROR: could not read the running kernel (uname -r)"; exit 1; }
    echo "Detected TrueNAS version: ${VERSION} (kernel: ${KVER})"

    # Find the release built for this kernel
    echo "Searching for a release matching this kernel..."
    export VERSION KVER
    # Fetch every releases page. The legacy releases the version fallback needs
    # are the oldest, exactly the ones a single newest-first page drops once
    # the repo outgrows it. Each page's JSON array is appended as-is; the
    # selection snippet merges them and reports API error objects.
    RELEASES_JSON="${WORK_DIR}/releases.json"
    : > "$RELEASES_JSON"
    PAGE=1
    while :; do
        PAGE_JSON=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${PAGE}") \
            || { echo "ERROR: Failed to query GitHub releases"; exit 1; }
        printf '%s\n' "$PAGE_JSON" >> "$RELEASES_JSON"
        # Only a full page can have more behind it; anything else (short page,
        # API error object) ends the loop.
        PAGE_LEN=$(printf '%s' "$PAGE_JSON" | python3 -c "
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len(doc) if isinstance(doc, list) else 0)
")
        [ "$PAGE_LEN" -eq 100 ] || break
        PAGE=$((PAGE + 1))
    done
    RELEASE_TAG=$(python3 -c "
# BEGIN release-selection (extracted verbatim by tests/test_release_selection.py;
# single-quoted strings only, \x60 stands for backtick, no dollar signs: this
# code lives inside a double-quoted bash string)
import sys, json, os, re
# stdin carries one JSON array per fetched API page, concatenated.
decoder = json.JSONDecoder()
text = sys.stdin.read()
data = []
pos = 0
while pos < len(text):
    if text[pos].isspace():
        pos += 1
        continue
    try:
        doc, pos = decoder.raw_decode(text, pos)
    except ValueError:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
    if isinstance(doc, dict) and 'message' in doc:
        msg = doc['message']
        if 'rate limit' in msg.lower():
            print('GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls).', file=sys.stderr)
            print('Wait a few minutes and try again.', file=sys.stderr)
        else:
            print(f'GitHub API error: {msg}', file=sys.stderr)
        sys.exit(1)
    elif isinstance(doc, list):
        data.extend(doc)
    else:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
if not text.strip():
    print('Failed to parse GitHub API response', file=sys.stderr)
    sys.exit(1)
version = os.environ['VERSION']
kver = os.environ['KVER']
# Channel gate: a BETA/RC box is on the preview channel and may install
# prereleases (preview builds are never promoted). A stable box only installs
# promoted (non-prerelease) builds: an unverified stable build stays a
# prerelease until a human closes its hardware-test issue, and auto-installing
# one would bypass that gate.
vu = version.upper()
is_preview = ('-BETA' in vu) or ('-RC' in vu)
ker_re = re.compile(r'Target kernel\s*\|\s*\x60([^\x60]+)\x60')
def target_kernel(release):
    m = ker_re.search(release.get('body') or '')
    return m.group(1) if m else ''
# Train guard (hailo divergence from coral): the sysext also ships userspace
# (libhailort, hailortcli) built against a train's base system, so a kernel
# match is only served from the box's own TrueNAS train. The train key is the
# first two numeric version components; a release with no parseable notes
# header passes (legacy releases are handled by the version fallback).
hdr_re = re.compile(r'for TrueNAS SCALE (\S+)')
def train_key(v):
    return '.'.join(v.partition('-')[0].split('.')[:2])
def same_train(release):
    m = hdr_re.search(release.get('body') or '')
    if not m:
        return True
    return train_key(m.group(1)) == train_key(version)
def preview_release(release):
    # Kernel-keyed tags (k6.18.23-...) carry no BETA marker, so the tag
    # check alone stopped covering new preview builds; the notes header
    # still names the TrueNAS version they were built for.
    tu = release.get('tag_name', '').upper()
    if ('-BETA' in tu) or ('-RC' in tu):
        return True
    m = hdr_re.search(release.get('body') or '')
    hv = m.group(1).upper() if m else ''
    return ('-BETA' in hv) or ('-RC' in hv)
# A stable box also refuses preview (BETA/RC) releases outright. The old
# version-prefix match made installing one structurally impossible; with
# kernel matching, the prerelease flag alone would be one mispublished
# release away from serving a beta build to stable boxes.
candidates = [r for r in data
              if not r.get('draft')
              and (is_preview or (not r.get('prerelease') and not preview_release(r)))]
# The Target kernel notes row is the primary key. A k-tag whose body lost
# the row still encodes its short kernel in the tag; check-releases counts
# such a release as covering its kernel (and skips builds for it), so the
# installer must serve it by the same rule. A body row always wins over the
# tag: it is written from REAL_KVER at build time, so a tag/body mismatch
# means a mispublished release that must not be served.
short = kver.split('-')[0]
def kernel_match(release):
    tk = target_kernel(release)
    if tk:
        return tk == kver
    return release.get('tag_name', '').startswith(f'k{short}-hailo')
matches = [r for r in candidates if kernel_match(r) and same_train(r)]
cross = [r for r in candidates if kernel_match(r) and not same_train(r)]
for r in cross:
    print('WARNING: ' + r.get('tag_name', '?') + ' matches kernel ' + kver
          + ' but was built for a different TrueNAS train; not using it'
          + ' (hailo userspace must match the train).', file=sys.stderr)
if not matches:
    # Releases published before the Target kernel row existed can only be
    # matched the old way: exact TrueNAS version. Never fall back onto a
    # release that DOES advertise a kernel: a version match with the wrong
    # kernel would ship modules that cannot load.
    prefix = f'v{version}-'
    matches = [r for r in candidates
               if r.get('tag_name', '').startswith(prefix) and not target_kernel(r)]
    if matches:
        print(f'NOTE: no release advertises kernel {kver}; matched by TrueNAS version instead.', file=sys.stderr)
if not matches:
    channel = 'preview (beta)' if is_preview else 'stable'
    print(f'No {channel} release found for kernel {kver} (TrueNAS {version}).', file=sys.stderr)
    # not preview_release: previews never promote, so the hint would be false
    pending = [r for r in data
               if not r.get('draft') and r.get('prerelease')
               and not preview_release(r)
               and target_kernel(r) == kver]
    if pending and not is_preview:
        print('A build for this kernel exists but is a prerelease awaiting hardware-test', file=sys.stderr)
        print('promotion; it installs automatically once promoted.', file=sys.stderr)
    print('Otherwise a build may not exist yet (the daily check builds within ~24h of an', file=sys.stderr)
    print('ISO going live), or you can build one yourself from the repo. Available releases:', file=sys.stderr)
    for r in [x for x in data if not x.get('draft')]:
        t = r.get('tag_name', '?')
        k = target_kernel(r) or 'no kernel recorded'
        mark = ' (prerelease)' if r.get('prerelease') else ''
        print(f'  {t} ({k}){mark}', file=sys.stderr)
    sys.exit(1)
matches.sort(key=lambda r: r.get('published_at') or r.get('created_at') or '', reverse=True)
print(matches[0]['tag_name'], end='')
# END release-selection
" < "$RELEASES_JSON") || { echo "ERROR: Failed to query GitHub releases"; exit 1; }

    echo "Found release: ${RELEASE_TAG}"

    # Download hailo.raw and checksum
    BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
    echo "Downloading hailo.raw..."
    curl -fSL --max-time 600 "${BASE_URL}/hailo.raw" -o "${WORK_DIR}/hailo.raw" || { echo "ERROR: Failed to download hailo.raw"; exit 1; }
    curl -fSL --max-time 600 "${BASE_URL}/hailo.raw.sha256" -o "${WORK_DIR}/hailo.raw.sha256" || { echo "ERROR: Failed to download checksum"; exit 1; }

    # Validate downloads are non-empty
    [ -s "${WORK_DIR}/hailo.raw" ] || { echo "ERROR: hailo.raw is empty"; exit 1; }
    [ -s "${WORK_DIR}/hailo.raw.sha256" ] || { echo "ERROR: checksum file is empty"; exit 1; }

    # Verify checksum
    echo "Verifying checksum..."
    if ! (cd "$WORK_DIR" && sha256sum -c hailo.raw.sha256); then
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

# Resolve HailoRT version and the expected firmware sha256.
#
# Each release is self-describing: build.yml uploads firmware.sha256 as an
# asset alongside hailo.raw, so the sha is paired with the release being
# installed (see #24). install.sh consults nothing outside the release.
#
#   Release flow:   tag → HAILO_VERSION, ${BASE_URL}/firmware.sha256 → expected sha
#   --local-raw:    user supplies --firmware-version and --expected-firmware-sha
#
# No tracked-versions.json fetch, no main fallback: cross-source mismatches
# (the original #22 bug) are structurally impossible.
HAILO_VERSION=""
PUBLISHED_FW_SHA=""

if [ -n "${RELEASE_TAG:-}" ]; then
    # Extract the hailo version from tags like:
    #   v25.10.2.1-hailo4.20.0                 (legacy, pre-issue-#17)
    #   v25.10.3-hailo4.21.0-g7854543          (legacy, SHA-suffixed)
    #   v25.10.3.1-hailo4.21.0-r23             (legacy, run-number suffix)
    #   k6.12.91-hailo4.21.0-r41               (current, kernel-keyed)
    # The capture stops at the first non-[0-9.] char after `hailo`, so any
    # `-r<run>` / `-g<sha>` suffix is left out of $HAILO_VERSION.
    HAILO_VERSION=$(echo "$RELEASE_TAG" | sed -n 's/.*hailo\([0-9][0-9.]*\).*/\1/p')
    if [ -z "$HAILO_VERSION" ]; then
        echo "ERROR: Could not parse HailoRT version from release tag '${RELEASE_TAG}'." >&2
        echo "  Expected format: k<kernel>-hailo<driver>-r<run> (or legacy v<truenas>-hailo<driver>[-r<run>])" >&2
        exit 1
    fi

    # Fetch firmware.sha256 from the same release. A 404 here means the
    # release predates per-release sha pinning (issue #24) — refuse rather
    # than fall back to main, which is what produced the original cross-
    # source mismatch.
    FW_SHA_URL="${BASE_URL}/firmware.sha256"
    echo "Fetching expected firmware sha256: ${FW_SHA_URL}"
    if ! PUBLISHED_FW_SHA=$(curl -fsSL --max-time 30 "$FW_SHA_URL" 2>/dev/null); then
        echo "ERROR: Release ${RELEASE_TAG} has no firmware.sha256 asset." >&2
        echo "  This release predates per-release firmware pinning (see #24)." >&2
        echo "  GitHub burns releases immutable after a few days, so the asset" >&2
        echo "  cannot be added retroactively. Options:" >&2
        echo "    - Wait for / request a fresh build for your TrueNAS version" >&2
        echo "      (dispatch build.yml in ${REPO})" >&2
        echo "    - Run with a local hailo.raw and supply the override:" >&2
        echo "      sudo ./install.sh /path/to/hailo.raw \\" >&2
        echo "        --firmware-version=<X.Y.Z> --expected-firmware-sha=<hex>" >&2
        exit 1
    fi
    PUBLISHED_FW_SHA=$(printf '%s' "$PUBLISHED_FW_SHA" | tr -d '[:space:]')
else
    # --local-raw path: no release tag, so no asset to fetch. Require the
    # user to supply both --firmware-version and --expected-firmware-sha.
    if [ -z "$LOCAL_FW_VERSION" ] || [ -z "$EXPECTED_FW_SHA" ]; then
        echo "ERROR: --local-raw requires both --firmware-version=X.Y.Z and --expected-firmware-sha=<hex>." >&2
        echo "  Without a release tag there is no firmware.sha256 asset to consult." >&2
        exit 1
    fi
    HAILO_VERSION="$LOCAL_FW_VERSION"
    PUBLISHED_FW_SHA="$EXPECTED_FW_SHA"
fi

if ! printf '%s' "$PUBLISHED_FW_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    echo "ERROR: Expected firmware sha256 is not a 64-char hex string: '${PUBLISHED_FW_SHA}'" >&2
    exit 1
fi

echo "HailoRT version: ${HAILO_VERSION}"
FW_URL="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/${HAILO_VERSION}/FW/hailo8_fw.${HAILO_VERSION}.bin"

echo "Downloading firmware from Hailo..."
if ! curl -fSL --max-time 600 "$FW_URL" -o "${WORK_DIR}/hailo8_fw.bin"; then
    echo "ERROR: Failed to download firmware from ${FW_URL}"
    echo "  Cannot install sysext without firmware — aborting."
    exit 1
fi
if [ ! -s "${WORK_DIR}/hailo8_fw.bin" ]; then
    echo "ERROR: Downloaded firmware is empty, aborting."
    rm -f "${WORK_DIR}/hailo8_fw.bin"
    exit 1
fi
echo "Firmware downloaded: $(ls -lh "${WORK_DIR}/hailo8_fw.bin")"

echo "Verifying firmware sha256..."
LOCAL_FW_SHA=$(sha256sum "${WORK_DIR}/hailo8_fw.bin" | awk '{print $1}')
echo "  local sha256:  ${LOCAL_FW_SHA}"
echo "  expected:      ${PUBLISHED_FW_SHA}"

if [ "$LOCAL_FW_SHA" != "$PUBLISHED_FW_SHA" ]; then
    echo "ERROR: Firmware sha256 mismatch — refusing to install" >&2
    echo "  expected: ${PUBLISHED_FW_SHA}" >&2
    echo "  got:      ${LOCAL_FW_SHA}" >&2
    echo "  The release's firmware.sha256 disagrees with what Hailo's S3 served." >&2
    echo "  Either the S3 binary changed under us, or the release asset is corrupt." >&2
    echo "  Open an issue on ${REPO}." >&2
    rm -f "${WORK_DIR}/hailo8_fw.bin"
    exit 1
fi
echo "Firmware sha256 OK"

# --- Inject firmware into hailo.raw squashfs ---
echo "Injecting firmware into hailo.raw..."
if command -v unsquashfs &>/dev/null && command -v mksquashfs &>/dev/null; then
    unsquashfs -d "${WORK_DIR}/hailo-sysext-unpack" "${WORK_DIR}/hailo.raw"
    mkdir -p "${WORK_DIR}/hailo-sysext-unpack/usr/lib/firmware/hailo"
    cp "${WORK_DIR}/hailo8_fw.bin" "${WORK_DIR}/hailo-sysext-unpack/usr/lib/firmware/hailo/hailo8_fw.bin"
    # Pull the PREINIT script out of the unpacked sysext while we have it
    # open. The sysext is the source of truth: whatever hailo.raw the user
    # installs ships with the matching preinit.
    BUNDLED_PREINIT="${WORK_DIR}/hailo-sysext-unpack/usr/lib/hailo/hailo-preinit.sh"
    if [ ! -f "$BUNDLED_PREINIT" ]; then
        echo "ERROR: hailo-preinit.sh not found in sysext at /usr/lib/hailo/hailo-preinit.sh" >&2
        echo "  This hailo.raw was built before the preinit script was bundled in." >&2
        echo "  Re-fetch a current release: https://github.com/${REPO}/releases/latest" >&2
        exit 1
    fi
    cp "$BUNDLED_PREINIT" "${WORK_DIR}/hailo-preinit.sh"
    chmod +x "${WORK_DIR}/hailo-preinit.sh"
    mksquashfs "${WORK_DIR}/hailo-sysext-unpack" "${WORK_DIR}/hailo.raw" -noappend -comp zstd -all-root
    rm -rf "${WORK_DIR}/hailo-sysext-unpack"
    echo "Firmware injected into hailo.raw"
else
    echo "ERROR: squashfs-tools not found, cannot inject firmware into sysext"
    echo "  Install squashfs-tools: apt-get install squashfs-tools"
    exit 1
fi

# --- Verify the image was built for the running kernel ---
# The selected release should already match uname -r, but the legacy version
# fallback and a hand-supplied hailo.raw can still deliver modules built for a
# different kernel, which can never load. Refuse before touching the system:
# without this check the install "succeeds", registers persistence, and the
# user reboots into a sysext whose modules never come up.
echo ""
echo "=== Verifying image kernel ==="
RUNNING_KVER=$(uname -r)
# || true: unsquashfs exits nonzero on an unmatched pattern, and pipefail
# would kill the script before the no-module-directory diagnostic prints.
IMAGE_MODULE_DIRS=$(unsquashfs -l "${WORK_DIR}/hailo.raw" 'usr/lib/modules/*' 2>/dev/null \
    | sed -n 's|^squashfs-root/usr/lib/modules/\([^/]*\)/.*|\1|p' | sort -u) || true
if ! printf '%s\n' "$IMAGE_MODULE_DIRS" | grep -qxF "$RUNNING_KVER"; then
    echo "ERROR: this hailo.raw was not built for the running kernel (${RUNNING_KVER})." >&2
    if [ -n "$IMAGE_MODULE_DIRS" ]; then
        echo "  Kernels in the image:" >&2
        printf '%s\n' "$IMAGE_MODULE_DIRS" | sed 's/^/    /' >&2
    else
        echo "  The image contains no kernel module directory at all." >&2
    fi
    echo "  Its modules could never load. Get the build for this kernel from:" >&2
    echo "  https://github.com/${REPO}/releases" >&2
    exit 1
fi
echo "Image kernel matches running kernel (${RUNNING_KVER})"

echo ""
echo "=== Installing hailo.raw ==="

# --- Detect persistent storage pool ---
# The sysext image lives only on the data pool; /run/extensions points at it
# directly. Resolve the pool first so the blob is in place before we activate.
if ! resolve_persist_dir; then
    echo "ERROR: No persistent storage pool found; cannot install." >&2
    exit 1
fi
echo "Persistent config directory: ${PERSIST_DIR}"
if_real mkdir -p "$PERSIST_DIR"
HAILO_RAW="${PERSIST_DIR}/hailo.raw"

# Write the sysext image to the data pool. This is the single copy we activate
# and the one that survives reboots and TrueNAS updates (no boot-pool copy).
echo "Installing hailo.raw to ${HAILO_RAW}..."
if_real cp "${WORK_DIR}/hailo.raw" "${HAILO_RAW}"

# Remove hailo from sysext before modifying. If nothing is currently merged,
# unmerge exits non-zero with "No extensions found" on stderr, which is fine.
# A real failure (overlay held open by another process) must not be swallowed.
echo "Removing old hailo sysext symlink..."
if_real rm -f /run/extensions/hailo.raw
if [ "$DRY_RUN" != "1" ]; then
    UNMERGE_ERR=$(systemd-sysext unmerge 2>&1) || {
        if printf '%s' "$UNMERGE_ERR" | grep -qi "no extensions"; then
            true  # nothing was merged, harmless
        else
            echo "ERROR: systemd-sysext unmerge failed: ${UNMERGE_ERR}" >&2
            echo "  Another process may be holding the overlay open." >&2
            echo "  Identify it with: lsof /usr/lib/firmware/hailo" >&2
            exit 1
        fi
    }
else
    echo "[dry-run] would: systemd-sysext unmerge"
fi

# Activate sysext via symlink + refresh (TrueNAS middleware pattern).
# systemd-sysext loop-mounts the symlink target wherever it lives, so pointing
# at the ZFS data-pool path works the same as a boot-pool path would.
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

# The sysext image (${PERSIST_DIR}/hailo.raw) and its activation symlink were
# put in place during install above. Here we record metadata and register the
# boot-time PREINIT script that re-creates the symlink after each reboot.

# Save HailoRT version for reference
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write \$HAILO_VERSION (${HAILO_VERSION}) to ${PERSIST_DIR}/.hailo-driver-version"
else
    printf '%s' "$HAILO_VERSION" > "${PERSIST_DIR}/.hailo-driver-version"
fi

# Save source repo so the boot-time PREINIT script can point users at the right
# releases page when a kernel mismatch is detected.
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write \$REPO (${REPO}) to ${PERSIST_DIR}/.hailo-repo"
else
    printf '%s' "$REPO" > "${PERSIST_DIR}/.hailo-repo"
fi

# --- Install PREINIT script to persistent storage ---
# Source is ${WORK_DIR}/hailo-preinit.sh, extracted from the unsquashed
# sysext earlier (see "Inject firmware" block). Bundling the script in the
# sysext means the hailo.raw release artifact is self-contained.
echo "Installing PREINIT script..."

# Clean up old postinit script if present
if_real rm -f "${PERSIST_DIR}/hailo-postinit.sh"

if_real cp "${WORK_DIR}/hailo-preinit.sh" "${PERSIST_DIR}/hailo-preinit.sh"
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
    echo "  Sysext image:      ${HAILO_RAW}"
    echo "  Persistent dir:    ${PERSIST_DIR}"
    echo "  HailoRT version:   ${HAILO_VERSION}"
    [ -n "${RELEASE_TAG:-}" ] && echo "  Release tag:       ${RELEASE_TAG}"
fi
