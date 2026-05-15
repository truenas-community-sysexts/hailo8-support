# How It Works

## Build Process

This project compiles the Hailo driver standalone (~15-30 minutes):

1. Downloads the TrueNAS ISO for the target version
2. Extracts kernel headers from the nested rootfs squashfs
3. Detects the real kernel version (e.g., `6.12.33-production+truenas`)
4. Compiles `hailo_pci.ko` with gcc-12 against those exact headers
5. Builds HailoRT userspace (libhailort, hailortcli) from source
6. Packages everything as a squashfs sysext image (without firmware)

The runner image is resolved per-build from TrueNAS's published Debian release (`bookworm` → `ubuntu-22.04`), so binaries link against a GLIBC that's no newer than the TrueNAS rootfs's. See [Build runner resolution](architecture.md#build-runner-resolution) for the lookup path.

## Firmware Handling

Hailo-8 firmware is proprietary and this project does not redistribute it. Instead:

- At **install time**: firmware is downloaded from Hailo's S3 servers and injected into the sysext squashfs
- At **boot time**: the backed-up sysext already contains firmware — no network access needed
- The firmware version is determined from the release tag (e.g., `v25.10.2.1-hailo4.21.0` → version `4.21.0`)

## TrueNAS-Specific Details

- **Sysext activation** uses TrueNAS's middleware pattern (symlink in `/run/extensions/` + `systemd-sysext refresh`), not the standard `systemd-sysext merge`
- **Module loading** uses `insmod` instead of `modprobe` because `/lib/modules` is on a read-only ZFS dataset where `depmod` cannot write
- **Firmware** is injected into the sysext squashfs because `/lib/firmware` is also read-only

## Automated Updates

A single daily GitHub Actions workflow (`check-releases.yml`, 06:00 UTC) monitors both upstreams and updates `.github/tracked-versions.json`:

- **TrueNAS half**: looks for new TrueNAS SCALE releases (highest stable `TS-*` tag in `truenas/scale-build`). When the matching ISO is live at `download.truenas.com`, it stages a bump of `truenas.version` (and `truenas.train` on a train rollover).
- **HailoRT half**: looks for new tags reachable from `hailort-drivers`'s `hailo8` branch, capped at the version pinned in Frigate's `docker/main/install_hailort.sh` on `dev`. When the cap allows, it stages a bump of `hailo.driver`.

If anything moved, the workflow writes the file in one commit, syncs `build.yml`'s dispatch defaults, and dispatches one build. Auto-builds publish releases without the "Latest" badge -- verify the build on Hailo-8 hardware, then promote it to Latest manually in the GitHub UI.

## Custom Builds

If you need a build for a TrueNAS version or HailoRT version that doesn't have a pre-built release, you can build your own using GitHub Actions — no local build environment needed.

### Fork and Build

1. **Fork** this repository on GitHub
2. Go to **Actions** > **Build Hailo Sysext** > **Run workflow**
3. Fill in the parameters:
   - **TrueNAS version** — e.g., `25.10.2.1` (must match an existing TrueNAS ISO on the download server)
   - **HailoRT driver version** — e.g., `4.21.0` (must match a tag in [hailo-ai/hailort-drivers](https://github.com/hailo-ai/hailort-drivers))
   - **Train name** — e.g., `Goldeye` (must match the train iXsystems publishes the ISO under at `download.truenas.com/TrueNAS-SCALE-<train>/<version>/`; the build uses it to construct the ISO download URL). The current tracked train lives in [`.github/tracked-versions.json`](../.github/tracked-versions.json).
4. The workflow builds `hailo.raw` and creates a GitHub release in your fork (~15-30 min, ~5 min cached)
5. Use the install script from your fork's release, or download `hailo.raw` and install manually

### When to Build Custom

- **New TrueNAS release** not yet covered by a pre-built release (the daily check workflow usually catches these within 24 hours of the ISO going live)
- **Different HailoRT version** — you want to test a newer or older driver version
- **Modified build** — you've forked the repo to change build options, add patches, etc.

### Version Defaults

The `workflow_dispatch` inputs default to the currently tracked combination from `.github/tracked-versions.json` plus the runner resolved from TrueNAS's Debian release. The defaults are kept in lockstep automatically: every auto-bump commit invokes `.github/scripts/sync-build-defaults.sh` to rewrite `build.yml`'s defaults alongside the state file, so a manual "Run workflow" always pre-fills the latest known-good combo. You can still override any field at dispatch time if you want a different target.
