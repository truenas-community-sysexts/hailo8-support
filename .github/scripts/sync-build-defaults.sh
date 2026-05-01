#!/usr/bin/env bash
# Sync workflow_dispatch defaults in .github/workflows/build.yml with the
# tracked-versions state. Invoked by .github/workflows/check-releases.yml
# after it writes .github/tracked-versions.json or resolves a build runner,
# so a manual dispatch from the Actions UI always pre-fills the latest
# tracked combination.
#
# Usage:
#   sync-build-defaults.sh KEY=VALUE [KEY=VALUE ...]
#
# Recognized keys: truenas_version, hailo_driver_version, train_name, runner.
# The substitution is scoped to the workflow_dispatch block by anchoring on
# the `description:` line, which workflow_call inputs do not have. Each KEY
# must produce a real change (or already match) — a structural mismatch
# (e.g. YAML restructure) fails loudly so a silent no-op cannot ship a
# stale default.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 KEY=VALUE [KEY=VALUE ...]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"

if [ ! -f "$BUILD_YML" ]; then
  echo "::error title=sync-build-defaults::build.yml not found at ${BUILD_YML}" >&2
  exit 1
fi

valid_key() {
  case "$1" in
    truenas_version|hailo_driver_version|train_name|runner) return 0 ;;
    *) return 1 ;;
  esac
}

sync_one() {
  local key="$1" value="$2" before after

  before=$(sha256sum "$BUILD_YML" | awk '{print $1}')

  # GNU sed -z treats the file as one record so the regex can span lines.
  # The 4-line block (key / description / required / default) is anchored
  # by `description:`, which only appears in workflow_dispatch — not in
  # workflow_call — so we cannot accidentally rewrite a workflow_call
  # default (e.g. mark_latest's).
  sed -i -E -z \
    "s|(\n      ${key}:\n        description: [^\n]*\n        required: true\n        default: ')[^']*(')|\1${value}\2|" \
    "$BUILD_YML"

  after=$(sha256sum "$BUILD_YML" | awk '{print $1}')

  # Structural verification: the key must exist in the dispatch block at
  # the expected indent. If sed silently no-op'd because the YAML shape
  # changed, this catches it. If the value already matched (legitimate
  # no-op), the structural check still passes.
  if ! grep -qE "^      ${key}:\$" "$BUILD_YML"; then
    echo "::error title=sync-build-defaults::no '${key}:' input found in ${BUILD_YML}" >&2
    return 1
  fi

  # Tightened value check: require the default to appear *immediately
  # below* the workflow_dispatch description block (which only exists in
  # workflow_dispatch). The previous file-wide grep could be satisfied by
  # workflow_call's identical default, masking a silent sed no-op caused
  # by a workflow_dispatch restructure (e.g. someone adding `type:`).
  # `grep -Pz` treats input as null-separated, enabling multi-line patterns.
  if ! grep -qPz "      ${key}:\n        description: [^\n]*\n        required: true\n        default: '${value}'\n" "$BUILD_YML"; then
    echo "::error title=sync-build-defaults::expected '${key}' default to be '${value}' inside workflow_dispatch after sync, but it is not" >&2
    return 1
  fi

  if [ "$before" = "$after" ]; then
    echo "  ${key}=${value} (already current)"
  else
    echo "  ${key}=${value} (updated)"
  fi
}

echo "Syncing build.yml workflow_dispatch defaults:"
for arg in "$@"; do
  if [[ "$arg" != *=* ]]; then
    echo "::error title=sync-build-defaults::argument '${arg}' is not KEY=VALUE" >&2
    exit 1
  fi
  key="${arg%%=*}"
  value="${arg#*=}"
  if ! valid_key "$key"; then
    echo "::error title=sync-build-defaults::unknown key '${key}' (allowed: truenas_version, hailo_driver_version, train_name, runner)" >&2
    exit 1
  fi
  if [ -z "$value" ]; then
    echo "::error title=sync-build-defaults::empty value for '${key}'" >&2
    exit 1
  fi
  sync_one "$key" "$value"
done
