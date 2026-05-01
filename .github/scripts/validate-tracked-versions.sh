#!/usr/bin/env bash
# Validate that .github/tracked-versions.json has the shape the rest of the
# CI machinery (check-releases.yml, sync-build-defaults.sh) assumes.
#
# Run locally:
#   .github/scripts/validate-tracked-versions.sh
# Exits non-zero with a `::error::` annotation on any shape violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${REPO_ROOT}/.github/tracked-versions.json"

if [ ! -f "$FILE" ]; then
  echo "::error title=tracked-versions::file not found: ${FILE}" >&2
  exit 1
fi

python3 - "$FILE" <<'PY'
import json
import re
import sys

path = sys.argv[1]

def fail(msg):
    print(f"::error title=tracked-versions::{msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    fail(f"invalid JSON in {path}: {e}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

# Match the shape check-releases.yml's tag parser will accept: 2-or-more
# numeric parts. Today's TrueNAS tags are 3- or 4-part (25.10.3, 25.10.3.1)
# but a future train (e.g. TS-26.0) could legitimately be 2-part. Capping at
# 5 parts so a runaway tag still trips the gate.
ver_re = re.compile(r"^\d+(\.\d+){1,4}$")
# Hailo uses strict semver: X.Y.Z only (no 4-part variants).
hailo_ver_re = re.compile(r"^\d+\.\d+\.\d+$")
sha256_re = re.compile(r"^[0-9a-f]{64}$")

truenas = data.get("truenas")
if not isinstance(truenas, dict):
    fail("'truenas' key missing or not an object")

tn_version = truenas.get("version")
if not isinstance(tn_version, str) or not ver_re.match(tn_version):
    fail(f"'truenas.version' missing or malformed (got {tn_version!r}); expected X.Y[.Z[.W[.V]]]")

tn_train = truenas.get("train")
if not isinstance(tn_train, str) or not tn_train.strip():
    fail(f"'truenas.train' missing or empty (got {tn_train!r})")

hailo = data.get("hailo")
if not isinstance(hailo, dict):
    fail("'hailo' key missing or not an object")

h_driver = hailo.get("driver")
if not isinstance(h_driver, str) or not hailo_ver_re.match(h_driver):
    fail(f"'hailo.driver' missing or malformed (got {h_driver!r}); expected X.Y.Z")

h_fw_sha = hailo.get("firmware_sha256")
if not isinstance(h_fw_sha, str) or not sha256_re.match(h_fw_sha):
    fail(f"'hailo.firmware_sha256' missing or malformed (got {h_fw_sha!r}); expected lowercase 64-char hex sha256")

print(f"tracked-versions OK: TrueNAS {tn_version} ({tn_train}), HailoRT {h_driver} (fw {h_fw_sha[:8]}…)")
PY
