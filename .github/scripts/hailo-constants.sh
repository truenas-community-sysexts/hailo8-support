#!/usr/bin/env bash
# Shared constants for Hailo CI scripts.
# Sourced by build.yml and backfill-firmware-sha.sh.

HAILO_FW_URL_TEMPLATE="https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/{VERSION}/FW/hailo8_fw.{VERSION}.bin"

hailo_fw_url() {
  local version="$1"
  printf '%s' "${HAILO_FW_URL_TEMPLATE//\{VERSION\}/$version}"
}
