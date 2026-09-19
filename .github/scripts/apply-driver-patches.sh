#!/usr/bin/env bash
# Apply local patches to the cloned hailort-drivers tree before building.
#
# Usage:
#   apply-driver-patches.sh <hailort-drivers-checkout> <patches-dir>
#
# Every *.patch in <patches-dir> (lexical order) is applied idempotently
# against the git checkout at <hailort-drivers-checkout>:
#
#   - if it already reverse-applies  -> the change is present upstream for
#                                       this driver version; skip it
#   - else if it forward-applies     -> apply it
#   - else                           -> fail loud
#
# The loud failure is the point: we pin the driver to whatever Frigate
# bundles (currently 4.21.0), and these patches carry fixes that the
# pinned tag lacks. If the upstream source shape drifts so a patch no
# longer applies, that is a signal to re-review the patch against the new
# version BEFORE shipping a driver that silently misses the fix — not
# something to paper over by skipping.
#
# Run locally against a checkout:
#   git clone --branch v4.21.0 https://github.com/hailo-ai/hailort-drivers /tmp/d
#   .github/scripts/apply-driver-patches.sh /tmp/d "$PWD/patches"
set -euo pipefail

SRC_DIR="${1:?usage: apply-driver-patches.sh <hailort-drivers-checkout> <patches-dir>}"
PATCH_DIR="${2:?usage: apply-driver-patches.sh <hailort-drivers-checkout> <patches-dir>}"

if [ ! -d "${SRC_DIR}/.git" ]; then
  echo "::error title=driver-patch::${SRC_DIR} is not a git checkout (git apply needs one)" >&2
  exit 1
fi
if [ ! -d "$PATCH_DIR" ]; then
  echo "No patches directory at ${PATCH_DIR} — nothing to apply"
  exit 0
fi

shopt -s nullglob
patches=("${PATCH_DIR}"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "No *.patch files in ${PATCH_DIR} — nothing to apply"
  exit 0
fi

cd "$SRC_DIR"
applied=0
for patch in "${patches[@]}"; do
  name="$(basename "$patch")"
  if git apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "= ${name}: already present in this driver version — skipping"
    continue
  fi
  if git apply --check "$patch" >/dev/null 2>&1; then
    git apply "$patch"
    echo "+ ${name}: applied"
    applied=$((applied + 1))
  else
    echo "::error title=driver-patch::${name} does not apply to the hailort-drivers checkout and is not already present. The upstream source shape changed — re-review the patch against this driver version before building." >&2
    exit 1
  fi
done

echo "Driver patches: ${applied} applied, $(( ${#patches[@]} - applied )) skipped/present"
