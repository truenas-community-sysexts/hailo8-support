#!/usr/bin/env bash
# Install the Hailo-8 sysext on TrueNAS from the newest build that a hardware
# test approved for this box's TrueNAS train, built for its running kernel.
#
#   curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/hailo8-support/main/get.sh | sudo bash
#
# Arguments go after `bash -s --` and pass through to the installer:
#
#   ... | sudo bash -s -- --pool=fast         # any install.sh flag
#   ... | sudo bash -s -- --check             # probe an existing install
#   ... | sudo bash -s -- --release=TAG       # that release, no selection
#   ... | sudo bash -s -- --uninstall         # remove it with the approved
#                                             # release's uninstall.sh
#
# What it does:
#   1. Reads the TrueNAS version (midclt call system.info) and derives the
#      train: the major version from 26 on (every 26.x release, betas
#      included, is train 26), major.minor before that (25.10). Reads the
#      running kernel (uname -r).
#   2. Lists this repo's releases and picks the newest build approved for
#      that train and built for that exact kernel (and, since the sysext
#      also ships userspace built against a train's base system, for that
#      train). A hardware test on a train approves a build for that train
#      only (promote.yml writes a verified-train marker into its notes); a
#      full release with no marker predates per-train sign-off and counts
#      for every train. Nothing else is ever installed, on stable or preview
#      (beta) boxes: with no approved build for this kernel it stops and
#      names the hardware test that is waiting.
#   3. Downloads THAT release's install.sh, hailo.raw, hailo.raw.sha256 and
#      firmware.sha256, verifies the image, and runs the release's own
#      installer on it with the firmware version and sha the release pins.
#      Every installer from r37 on takes a local image this way and then
#      never looks up a release of its own, so what installs is exactly the
#      approved build.
#
# --release=TAG skips steps 1 and 2 and uses TAG as given. --uninstall
# fetches the release's uninstall.sh and restore.sh instead; it, --check,
# --help and an image path of your own need only the release's scripts, so
# on a kernel with no approved build they use the newest release approved
# for the train. --repo=OWNER/NAME (or HAILO_REPO) points all of it at a
# fork.

set -euo pipefail

REPO="${HAILO_REPO:-truenas-community-sysexts/hailo8-support}"
WORK_DIR=""

# BEGIN approved-release (a verbatim copy lives in get.sh, scripts/install.sh
# and scripts/uninstall.sh, each a self-contained curl|bash script;
# tests/test_release_selection.py fails CI when the copies differ)

# TrueNAS version of this box, read from the middleware. Retried: midclt can
# be briefly unavailable right after boot.
detect_truenas_version() {
    local v i
    for i in 1 2 3; do
        v=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
        [ "$i" -lt 3 ] && sleep 1
    done
    return 1
}

# Train key of a TrueNAS version: the major version from 26 on (26.0.0-BETA.3
# and 26.1.2 are both train 26), major.minor before that (25.10.7 is 25.10,
# 25.04.2.6 is 25.04). Fails on anything else. The selection's train_key
# applies the same rule to the version in a release's notes header.
truenas_train_key() {
    local v="$1" major minor
    major="${v%%.*}"
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$major" -ge 26 ]; then
        printf '%s\n' "$major"
        return 0
    fi
    case "$v" in *.*) ;; *) return 1 ;; esac
    minor="${v#*.}"
    minor="${minor%%[!0-9]*}"
    [ -n "$minor" ] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

# Every page of the repo's releases, appended to $1 as one JSON array per
# page. The legacy releases the version fallback needs are the oldest,
# exactly the ones a single newest-first page drops once the repo outgrows
# it. Only a full page can have more behind it; anything else (short page,
# API error object) ends the loop, and the selection reports API errors.
fetch_release_pages() {
    local out="$1" page=1 page_json page_len
    : > "$out"
    while :; do
        page_json=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}") \
            || { echo "ERROR: Failed to query GitHub releases" >&2; return 1; }
        printf '%s\n' "$page_json" >> "$out"
        page_len=$(printf '%s' "$page_json" | python3 -c "
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len(doc) if isinstance(doc, list) else 0)
")
        [ "$page_len" -eq 100 ] || break
        page=$((page + 1))
    done
}

# The release for a box running TrueNAS $1 (train $3) on kernel $2, chosen
# from the release pages in $5. $4 is "install" (a build to install: it must
# target this kernel and train) or "scripts" (only the release's scripts are
# needed: uninstall, --check, --help). Prints its tag; explains on stderr and
# fails when there is none.
select_release() {
    VERSION="$1" KVER="$2" TRAIN="$3" PURPOSE="$4" REPO="$REPO" python3 -c "
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
# This box's train key, from truenas_train_key (same rule as train_key below).
train = os.environ['TRAIN']
repo = os.environ.get('REPO', '')
# scripts: the caller runs only this release's scripts (uninstall, --check,
# --help), which do not depend on the kernel.
scripts_only = os.environ.get('PURPOSE') == 'scripts'
# Channel gate: a BETA/RC box is on the preview channel. A stable box refuses
# preview builds outright (see preview_release below); what either channel
# installs is decided by the approval gate further down.
vu = version.upper()
is_preview = ('-BETA' in vu) or ('-RC' in vu)
ker_re = re.compile(r'Target kernel\s*\|\s*\x60([^\x60]+)\x60')
def target_kernel(release):
    m = ker_re.search(release.get('body') or '')
    return m.group(1) if m else ''
# Train guard (hailo divergence from coral): the sysext also ships userspace
# (libhailort, hailortcli) built against a train's base system, so a kernel
# match is only served from the box's own TrueNAS train. The train key is the
# major version from 26 on (every 26.x release, betas included, is one train)
# and major.minor before that; a release with no parseable notes header
# passes (legacy releases are handled by the version fallback).
hdr_re = re.compile(r'for TrueNAS SCALE (\S+)')
def train_key(v):
    major, dot, rest = v.partition('.')
    if not major.isdigit():
        return ''
    if int(major) >= 26:
        return major
    minor = re.match(r'[0-9]*', rest).group(0)
    return major + '.' + minor if dot and minor else ''
def same_train(release):
    m = hdr_re.search(release.get('body') or '')
    if not m:
        return True
    return train_key(m.group(1)) == train
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
# Approval gate. promote.yml writes one verified-train line into the notes
# when a hardware test on a train signs the build off. A release with a line
# for this train is approved here; lines for other trains only are not. A
# full release with no line at all predates per-train sign-off and is
# grandfathered. Nothing else qualifies: there is no fallback to an
# unverified build, on stable or preview boxes (preview builds stay
# prereleases, so only their line approves them).
vt_re = re.compile(r'^[ \t]*<!--\s*verified-train:\s*([^\s>]+?)\s*-->', re.M)
def verified_trains(release):
    return set(vt_re.findall(release.get('body') or ''))
def approved(release):
    trains = verified_trains(release)
    if trains:
        return train in trains
    return not release.get('prerelease') and not preview_release(release)
# A stable box also refuses preview (BETA/RC) releases outright. The old
# version-prefix match made installing one structurally impossible; with
# kernel matching, one mispublished release would otherwise be enough to
# serve a beta build to stable boxes.
candidates = [r for r in data
              if not r.get('draft')
              and approved(r)
              and (is_preview or not preview_release(r))]
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
for r in ([] if scripts_only else cross):
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
if not matches and scripts_only:
    # With no approved build for this kernel (a box on an untested kernel,
    # say), the scripts of the newest release approved for the train serve.
    matches = candidates
def published(release):
    return release.get('published_at') or release.get('created_at') or ''
if not matches:
    channel = 'preview (beta)' if is_preview else 'stable'
    print(f'No {channel} release found for kernel {kver} (TrueNAS {version}).', file=sys.stderr)
    print(f'Only a build a hardware test approved for TrueNAS train {train} is installed;', file=sys.stderr)
    print('nothing unapproved is, on stable or preview systems.', file=sys.stderr)
    # A build that would match but for the sign-off: name its hardware test.
    pending = sorted([r for r in data
                      if not r.get('draft') and not approved(r)
                      and (is_preview or not preview_release(r))
                      and kernel_match(r) and same_train(r)], key=published, reverse=True)
    if pending:
        print(f'A build for this kernel is awaiting hardware-test sign-off for train {train}.', file=sys.stderr)
        print('It installs once its test issue is closed as completed:', file=sys.stderr)
        for r in pending:
            t = r.get('tag_name', '?')
            label = 'preview-hardware-test' if preview_release(r) else 'hardware-test'
            print(f'  {t}: https://github.com/{repo}/issues?q=is%3Aissue+label%3A{label}+in%3Atitle+%22{t}%22', file=sys.stderr)
    print('Otherwise a build may not exist yet (the daily check builds within ~24h of an', file=sys.stderr)
    print('ISO going live), or you can build one yourself from the repo. Available releases:', file=sys.stderr)
    for r in [x for x in data if not x.get('draft')]:
        t = r.get('tag_name', '?')
        k = target_kernel(r) or 'no kernel recorded'
        mark = ' (prerelease)' if r.get('prerelease') else ''
        vt = sorted(verified_trains(r))
        if vt:
            mark += ' (approved for train ' + ', '.join(vt) + ')'
        print(f'  {t} ({k}){mark}', file=sys.stderr)
    sys.exit(1)
matches.sort(key=published, reverse=True)
print(matches[0]['tag_name'], end='')
# END release-selection
" < "$5"
}

# The release to use on this box: the newest one a hardware test approved for
# its TrueNAS train and built for its running kernel ($1 = install), or, when
# only the release's scripts are needed ($1 = scripts), the same release or,
# failing that, the newest one approved for the train. Prints the tag.
approved_release_tag() {
    local purpose="${1:-install}" version kver train pages tag
    version=$(detect_truenas_version) || {
        echo "ERROR: Failed to detect TrueNAS version (midclt call system.info)." >&2
        echo "  Run this as root on TrueNAS SCALE." >&2
        return 1
    }
    # The running kernel is the match key: kernel modules bind to the exact
    # kernel string, and many TrueNAS versions share one kernel, so the right
    # release is the one built for this kernel, whichever TrueNAS version
    # produced it.
    kver=$(uname -r 2>/dev/null) || kver=""
    [ -n "$kver" ] || { echo "ERROR: could not read the running kernel (uname -r)" >&2; return 1; }
    train=$(truenas_train_key "$version") || {
        echo "ERROR: cannot derive a TrueNAS train from version '${version}'" >&2
        return 1
    }
    echo "Detected TrueNAS version: ${version} (train ${train}, kernel: ${kver})" >&2
    if [ "$purpose" = scripts ]; then
        echo "Searching for the release approved for this train..." >&2
    else
        echo "Searching for a release matching this kernel..." >&2
    fi
    pages=$(mktemp) || return 1
    if fetch_release_pages "$pages" && tag=$(select_release "$version" "$kver" "$train" "$purpose" "$pages"); then
        rm -f "$pages"
        echo "Found release: ${tag}" >&2
        printf '%s\n' "$tag"
        return 0
    fi
    rm -f "$pages"
    return 1
}
# END approved-release

# Download release assets $2... of release $1 into WORK_DIR.
fetch_assets() {
    local tag="$1" asset
    shift
    for asset in "$@"; do
        curl -fsSL --retry 3 --max-time 600 -o "${WORK_DIR}/${asset}" \
            "https://github.com/${REPO}/releases/download/${tag}/${asset}" \
            || { echo "ERROR: could not download ${asset} from release ${tag}" >&2; return 1; }
    done
}

main() {
    local mode=install purpose=install tag="" arg fw_version fw_sha
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            --uninstall) mode=uninstall ;;
            --release=*)
                tag="${arg#*=}"
                [ -n "$tag" ] || { echo "ERROR: --release= needs a tag, e.g. --release=k6.18.42-hailo4.21.0-r47" >&2; exit 2; }
                ;;
            --repo=*)
                REPO="${arg#*=}"
                [ -n "$REPO" ] || { echo "ERROR: --repo= needs OWNER/NAME" >&2; exit 2; }
                ;;
            *) args+=("$arg") ;;
        esac
    done
    # Repo moved from scyto/truenas-hailo; redirect stale env-var/docs to the new slug.
    if [ "$REPO" = "scyto/truenas-hailo" ]; then
        echo "Note: 'scyto/truenas-hailo' has moved; using 'truenas-community-sysexts/hailo8-support'." >&2
        REPO="truenas-community-sysexts/hailo8-support"
    fi
    # The scripts below read the repo from the environment: install.sh's
    # --repo default and uninstall.sh's only override.
    export HAILO_REPO="$REPO"

    # Only an install needs the release's image. Uninstall, --check, --help
    # and a path to the user's own image run the release's scripts only.
    [ "$mode" = uninstall ] && purpose=scripts
    for arg in ${args[@]+"${args[@]}"}; do
        case "$arg" in --check|--help|[!-]*) purpose=scripts ;; esac
    done

    if [ -n "$tag" ]; then
        echo "Release ${tag} (pinned with --release)" >&2
    else
        tag=$(approved_release_tag "$purpose") || exit 1
    fi

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hailo-get.XXXXXX")
    trap 'rm -rf "$WORK_DIR"' EXIT

    if [ "$mode" = uninstall ]; then
        # uninstall.sh runs the restore.sh beside it; both come from the
        # release. They take no release argument: they only undo the install.
        fetch_assets "$tag" uninstall.sh restore.sh || exit 1
        bash "${WORK_DIR}/uninstall.sh" ${args[@]+"${args[@]}"}
        return
    fi

    fetch_assets "$tag" install.sh || exit 1
    if [ "$purpose" = install ]; then
        # The release's own image, checked the way install.sh checks a
        # download, goes to its installer as a local file. A local image
        # needs the firmware version (from the tag, as install.sh derives
        # it) and the expected firmware sha (the release's firmware.sha256).
        fetch_assets "$tag" hailo.raw hailo.raw.sha256 firmware.sha256 || exit 1
        [ -s "${WORK_DIR}/hailo.raw" ] || { echo "ERROR: hailo.raw from release ${tag} is empty" >&2; exit 1; }
        echo "Verifying checksum..." >&2
        (cd "$WORK_DIR" && sha256sum -c hailo.raw.sha256) >&2 \
            || { echo "ERROR: checksum verification failed for hailo.raw from release ${tag}" >&2; exit 1; }
        fw_version=$(printf '%s' "$tag" | sed -n 's/.*hailo\([0-9][0-9.]*\).*/\1/p')
        fw_version="${fw_version%.}"
        if ! printf '%s' "$fw_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "ERROR: could not read the HailoRT version from release tag '${tag}'" >&2
            exit 1
        fi
        fw_sha=$(tr -d '[:space:]' < "${WORK_DIR}/firmware.sha256")
        if ! printf '%s' "$fw_sha" | grep -qE '^[0-9a-f]{64}$'; then
            echo "ERROR: firmware.sha256 from release ${tag} is not a 64-char hex sha256" >&2
            exit 1
        fi
        args=("${WORK_DIR}/hailo.raw" "--firmware-version=${fw_version}" \
              "--expected-firmware-sha=${fw_sha}" ${args[@]+"${args[@]}"})
    fi
    bash "${WORK_DIR}/install.sh" ${args[@]+"${args[@]}"}
}

# Called on the last line, so bash has read this whole script before
# anything runs and the installer cannot swallow the rest of it from stdin.
main "$@"
