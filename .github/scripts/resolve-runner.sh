#!/usr/bin/env bash
# Resolve the GitHub Actions runner image that build.yml should use for a
# given TrueNAS SCALE release. The build needs to compile against the
# TrueNAS rootfs's GLIBC, which means the runner's GLIBC must be ≤ the
# rootfs's. Since TrueNAS is Debian-based, knowing TrueNAS's Debian release
# is enough to pick a compatible Ubuntu runner.
#
# Resolution path (two cheap fetches, ~32KB total):
#   1. download.truenas.com/TrueNAS-SCALE-<train>/<version>/GITMANIFEST
#      pins the truenas-build commit that produced the ISO.
#   2. raw.githubusercontent.com/truenas/truenas-build/<sha>/conf/build.manifest
#      declares `debian_release:` (e.g. "bookworm").
#   3. Map debian_release → an Ubuntu runner image with a compatible GLIBC.
#
# When TrueNAS rebases onto a newer Debian, the only change required here
# is one new entry in the case statement below. The auto-bump workflows
# will fail loud (::error::) on the first run after a rebase until the
# entry is added — that is the intended signal.
#
# Usage:
#   resolve-runner.sh <train> <version>
# Prints the runner image name on stdout (e.g. ubuntu-22.04).
# Fails non-zero with a ::error:: annotation on any unexpected state.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <train> <version>" >&2
  exit 2
fi

TRAIN="$1"
VERSION="$2"

if [ -z "$TRAIN" ] || [ -z "$VERSION" ]; then
  echo "::error title=resolve-runner::train and version must be non-empty (got train='${TRAIN}', version='${VERSION}')" >&2
  exit 1
fi

GITMANIFEST_URL="https://download.truenas.com/TrueNAS-SCALE-${TRAIN}/${VERSION}/GITMANIFEST"
if ! GITMANIFEST=$(curl -fsSL "$GITMANIFEST_URL"); then
  echo "::error title=resolve-runner::failed to fetch GITMANIFEST at ${GITMANIFEST_URL}" >&2
  exit 1
fi

# truenas-build pin format in GITMANIFEST is one line of the form:
#   https://github.com/truenas/truenas-build.git <sha>
# (with or without the .git suffix). Match exactly one line; zero or
# multiple is a structural surprise we surface rather than guess.
TRUENAS_BUILD_LINE=$(printf '%s\n' "$GITMANIFEST" \
  | grep -E '^https://github\.com/truenas/truenas-build(\.git)?[[:space:]]' \
  || true)
LINE_COUNT=$(printf '%s' "$TRUENAS_BUILD_LINE" | grep -c . || true)
if [ "$LINE_COUNT" -ne 1 ]; then
  echo "::error title=resolve-runner::expected exactly 1 truenas-build pin in GITMANIFEST, got ${LINE_COUNT}" >&2
  exit 1
fi
TRUENAS_BUILD_SHA=$(printf '%s' "$TRUENAS_BUILD_LINE" | awk '{print $2}')
if [ -z "$TRUENAS_BUILD_SHA" ]; then
  echo "::error title=resolve-runner::could not extract truenas-build SHA from line: ${TRUENAS_BUILD_LINE}" >&2
  exit 1
fi

MANIFEST_URL="https://raw.githubusercontent.com/truenas/truenas-build/${TRUENAS_BUILD_SHA}/conf/build.manifest"
if ! BUILD_MANIFEST=$(curl -fsSL "$MANIFEST_URL"); then
  echo "::error title=resolve-runner::failed to fetch truenas-build manifest at ${MANIFEST_URL}" >&2
  exit 1
fi

# `debian_release: "bookworm"` (quotes optional in YAML; tolerate either).
DEBIAN_RELEASE_LINE=$(printf '%s\n' "$BUILD_MANIFEST" \
  | grep -E '^debian_release:' \
  || true)
LINE_COUNT=$(printf '%s' "$DEBIAN_RELEASE_LINE" | grep -c . || true)
if [ "$LINE_COUNT" -ne 1 ]; then
  echo "::error title=resolve-runner::expected exactly 1 debian_release field in truenas-build@${TRUENAS_BUILD_SHA}/conf/build.manifest, got ${LINE_COUNT}" >&2
  exit 1
fi
DEBIAN_RELEASE=$(printf '%s' "$DEBIAN_RELEASE_LINE" \
  | sed -E 's/^debian_release:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/')
if [ -z "$DEBIAN_RELEASE" ]; then
  echo "::error title=resolve-runner::failed to parse debian_release value from line: ${DEBIAN_RELEASE_LINE}" >&2
  exit 1
fi

# Map Debian release → Ubuntu runner image. The runner's GLIBC must be
# ≤ the rootfs's, so we pin to an Ubuntu whose GLIBC is one step behind:
#   bookworm (GLIBC 2.36) → ubuntu-22.04 (GLIBC 2.35)
#   trixie   (GLIBC 2.41) → ubuntu-24.04 (GLIBC 2.39)
# When TrueNAS rebases, add the new arm here.
case "$DEBIAN_RELEASE" in
  bookworm) RUNNER='ubuntu-22.04' ;;
  trixie)   RUNNER='ubuntu-24.04' ;;
  *)
    echo "::error title=resolve-runner::unknown debian_release '${DEBIAN_RELEASE}' (TrueNAS ${TRAIN} ${VERSION}). Add a runner mapping in $(basename "$0")." >&2
    exit 1
    ;;
esac

# stdout = single line, runner image name. stderr = diagnostic context.
echo "resolve-runner: train=${TRAIN} version=${VERSION} truenas-build=${TRUENAS_BUILD_SHA:0:12} debian=${DEBIAN_RELEASE} → runner=${RUNNER}" >&2
printf '%s\n' "$RUNNER"
