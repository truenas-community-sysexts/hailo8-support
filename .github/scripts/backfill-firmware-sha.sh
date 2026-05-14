#!/usr/bin/env bash
# One-shot backfill: upload firmware.sha256 to every existing release that
# doesn't have one. Idempotent — re-running skips releases already covered.
#
# Why this exists: pre-#24 releases were built before build.yml uploaded a
# per-release firmware.sha256. The new install.sh fetches that asset from
# the release it's installing, so without backfill those old releases 404
# and install.sh refuses. Once every release has the asset, the "missing
# asset" failure mode disappears for any release the picker can land on.
#
# Usage: ./.github/scripts/backfill-firmware-sha.sh [--dry-run]
#
# Requires: gh CLI authenticated with `repo` scope, curl, sha256sum.

set -euo pipefail

REPO="${HAILO_REPO:-scyto/truenas-hailo}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Backfilling firmware.sha256 across releases of ${REPO}..."
[ "$DRY_RUN" = "1" ] && echo "(dry-run — no uploads)"

# Skip drafts: install.sh's release picker uses the unauthenticated
# /releases endpoint, which only returns published releases. Also surface
# immutable status — GitHub burns releases immutable a few days after
# publish (see issue #17), so older releases can't accept new assets.
# We still try, and report the failure as expected rather than as a bug.
RELEASES_FILE="${WORKDIR}/releases.tsv"
gh release list --repo "$REPO" --limit 100 --json tagName,isDraft,isImmutable \
    | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if not r['isDraft']:
        print(f\"{r['tagName']}\t{r['isImmutable']}\")
" > "$RELEASES_FILE"

uploaded=0
skipped_immutable=0
skipped_present=0
failed=0

# Read tab-separated tag<TAB>immutable lines. Avoid mapfile (bash 4+) so the
# script runs on macOS's stock bash 3.2.
while IFS=$'\t' read -r tag immutable; do
    [ -z "$tag" ] && continue

    if gh release view "$tag" --repo "$REPO" --json assets \
        | python3 -c "import json,sys; sys.exit(0 if any(a['name']=='firmware.sha256' for a in json.load(sys.stdin)['assets']) else 1)"; then
        echo "  ${tag}: already has firmware.sha256 — skipping"
        skipped_present=$((skipped_present+1))
        continue
    fi

    if [ "$immutable" = "True" ]; then
        echo "  ${tag}: release is immutable (GitHub-burned) — cannot upload, skipping"
        skipped_immutable=$((skipped_immutable+1))
        continue
    fi

    # Extract HailoRT version from the tag. Same regex install.sh uses.
    version=$(echo "$tag" | sed -n 's/.*hailo\([0-9][0-9.]*\).*/\1/p')
    if [ -z "$version" ]; then
        echo "  ${tag}: could not parse hailo version — skipping" >&2
        failed=$((failed+1))
        continue
    fi

    fw_url="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/${version}/FW/hailo8_fw.${version}.bin"
    fw_tmp="${WORKDIR}/hailo8_fw.${version}.bin"

    if [ ! -f "$fw_tmp" ]; then
        echo "  ${tag}: fetching ${fw_url}"
        if ! curl -fsSL --max-time 300 "$fw_url" -o "$fw_tmp"; then
            echo "  ${tag}: ERROR failed to fetch firmware from S3" >&2
            failed=$((failed+1))
            continue
        fi
    fi

    sha=$(sha256sum "$fw_tmp" | awk '{print $1}')
    if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{64}$'; then
        echo "  ${tag}: ERROR malformed sha256: ${sha}" >&2
        failed=$((failed+1))
        continue
    fi

    sha_file="${WORKDIR}/firmware.sha256"
    printf '%s\n' "$sha" > "$sha_file"
    echo "  ${tag}: hailo=${version} sha=${sha}"

    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] would upload ${sha_file} to release ${tag}"
        uploaded=$((uploaded+1))
    else
        if gh release upload "$tag" "$sha_file" --repo "$REPO" --clobber; then
            uploaded=$((uploaded+1))
        else
            echo "  ${tag}: ERROR upload failed" >&2
            failed=$((failed+1))
        fi
    fi
done < "$RELEASES_FILE"

echo ""
echo "Summary: ${uploaded} uploaded, ${skipped_present} already had asset, ${skipped_immutable} immutable, ${failed} failed"

echo "Done."
