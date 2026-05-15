# Build Pipeline Architecture

## Overview

This project builds a systemd-sysext package (`hailo.raw`) containing the Hailo-8 AI accelerator driver for TrueNAS SCALE. The sysext is a squashfs image that overlays `/usr/` via overlayfs when activated with `systemd-sysext refresh`.

**Important:** Hailo-8 firmware (`hailo8_fw.bin`) is proprietary and governed by Hailo's EULA, which prohibits redistribution. This project does **not** distribute firmware. Instead, the install script downloads firmware directly from Hailo's servers at install time and injects it into the sysext squashfs before activation.

## Why Not scale-build?

Hailo-8 is **not** in the TrueNAS build manifest. It's a standard out-of-tree kernel module that only needs:
- Kernel headers matching the target TrueNAS kernel
- Standard build toolchain (gcc, make, cmake)
- HailoRT source code

This means we can skip scale-build entirely, reducing build time from ~5-6 hours to ~15-30 minutes.

## Build Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│  Single GitHub Actions Job (runner resolved per-build)       │
│                                                              │
│  1. Download TrueNAS ISO (cached)                            │
│  2. Extract kernel headers from nested squashfs (cached)     │
│  3. Detect real kernel version from headers                  │
│  4. Clone hailort-drivers → build hailo_pci.ko (gcc-12)     │
│  5. Clone hailort → build libhailort + hailortcli (cached)  │
│  6. Assemble sysext tree (NO firmware, NO depmod)            │
│  7. mksquashfs → hailo.raw (zstd compressed)                │
│  8. Create GitHub release                                    │
└──────────────────────────────────────────────────────────────┘
```

### Build Environment

The runner image is resolved per-build so it stays compatible with whatever Debian release TrueNAS is on (the runner's GLIBC must be <= the TrueNAS rootfs's). For example, Debian Bookworm (GLIBC 2.36) maps to **ubuntu-22.04** (GLIBC 2.35); Ubuntu 24.04 (GLIBC 2.39) would produce binaries that won't run on a Bookworm-based rootfs. The current mapping table lives in [`.github/scripts/resolve-runner.sh`](../.github/scripts/resolve-runner.sh).

The kernel module is compiled with **gcc-12** because the TrueNAS kernel was built with GCC 12, which uses `-ftrivial-auto-var-init=zero` — a flag not supported by GCC 11 (ubuntu-22.04's default). The userspace components (hailortcli, libhailort) are built with the default GCC 11, which is fine for GLIBC compatibility.

#### Build runner resolution

Both auto-bump check workflows resolve the runner before dispatching `build.yml`, then pass it as an input. The lookup is two cheap fetches against TrueNAS's own published build metadata (no ISO download needed):

1. `download.truenas.com/TrueNAS-SCALE-<train>/<version>/GITMANIFEST` (~2 KB) pins the `truenas-build` commit that produced the ISO.
2. `raw.githubusercontent.com/truenas/truenas-build/<sha>/conf/build.manifest` declares `debian_release:` (e.g. `"bookworm"`).
3. A `case` statement in `.github/scripts/resolve-runner.sh` maps the Debian release to an Ubuntu runner image with a compatible GLIBC.

When TrueNAS rebases onto a new Debian release, the auto-bump checks fail loud (`::error::unknown debian_release '<codename>'`) on the first scheduled run after the rebase. The fix is a one-line addition to the `case` statement — detection is automated, the actual mapping decision stays human.

### Caching Strategy

Three levels of caching minimize build times:

| Cache | Key | Contents | Saves |
| --- | --- | --- | --- |
| TrueNAS ISO | `truenas-iso-{version}` | The ~1.3 GB ISO download | ~2-3 min |
| Kernel headers | `kernel-headers-v3-{version}` | Extracted headers + `.real-kver` | ~3-5 min |
| HailoRT build | `hailort-build-v2-{driver_version}` | Compiled libhailort + hailortcli | ~12 min |

Cache keys include version prefixes (e.g., `v3-`) to allow invalidation when the extraction logic changes.

### Step Detail: Kernel Header Extraction

TrueNAS ISOs have a nested squashfs structure:

```
TrueNAS-SCALE-25.10.2.1.iso
├── live/filesystem.squashfs      ← installer-only (NO kernel headers)
└── TrueNAS-SCALE.update          ← outer squashfs containing:
    └── rootfs.squashfs           ← full rootfs with headers at:
        └── usr/src/linux-headers-truenas-production-amd64/
```

The extraction step:

1. Mounts the ISO
2. Extracts `rootfs.squashfs` from `TrueNAS-SCALE.update`
3. Extracts `usr/src/linux-headers-*` and `lib/modules/*` from the rootfs
4. Selects the production headers (prefers `production` keyword, avoids `debug`)

### Step Detail: Kernel Version Detection

TrueNAS uses non-standard kernel header directory names. The header package is named `linux-headers-truenas-production-amd64`, but the actual kernel version (what `uname -r` returns) is something like `6.12.33-production+truenas`. These must match for the kernel module to load.

The build detects the real kernel version via:

1. **`include/config/kernel.release`** in the headers directory (most reliable)
2. **`/lib/modules/` directory names** from the rootfs (fallback)
3. **Header directory name** (last resort, may not work)

Both `KVER` (header dir name, used for compilation) and `REAL_KVER` (actual kernel version, used for module install path) are tracked separately.

### Step Detail: Kernel Module Build

```bash
cd hailort-drivers/linux/pcie
make CC=gcc-12 KERNEL_DIR=/path/to/linux-headers-<KVER> all
```

This produces `hailo_pci.ko`. The `CC=gcc-12` is critical — without it, GCC 11 fails on the `-ftrivial-auto-var-init=zero` flag baked into the kernel's build config.

### Step Detail: HailoRT Build

```bash
cd hailort
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr ..
make -j$(nproc)
```

Produces `libhailort.so` (runtime library) and `hailortcli` (CLI tool).

**CMake wrapper trap:** CMake generates shell wrapper scripts alongside the real ELF binaries in the build directory. The assembly step must check each candidate with `file` to ensure it copies the actual ELF binary, not the wrapper script.

### Step Detail: Sysext Assembly

The assembly step explicitly does **NOT**:

- Include firmware (downloaded at install time)
- Run `depmod` (would overwrite the base system's `modules.dep` via overlayfs, breaking all other kernel modules)

## Sysext Structure

```text
hailo.raw (squashfs, zstd compressed, ~3 MB without firmware)
└── usr/
    ├── lib/
    │   ├── extension-release.d/
    │   │   └── extension-release.hailo    # ID=_any
    │   ├── modules/<REAL_KVER>/
    │   │   └── extra/hailo_pci.ko
    │   ├── hailo/
    │   │   └── hailo-preinit.sh           # PREINIT script (extracted by install.sh)
    │   ├── x86_64-linux-gnu/
    │   │   ├── libhailort.so → libhailort.so.4.x.x
    │   │   └── libhailort.so.4.x.x
    │   ├── systemd/system/
    │   │   ├── hailo-load.service
    │   │   └── multi-user.target.wants/hailo-load.service → ../hailo-load.service
    │   └── udev/rules.d/
    │       └── 51-hailo-udev.rules
    └── bin/
        └── hailortcli
```

After firmware injection at install time, `usr/lib/firmware/hailo/hailo8_fw.bin` is also present.

### extension-release

The file `usr/lib/extension-release.d/extension-release.hailo` contains `ID=_any`, matching the pattern used by TrueNAS's own NVIDIA sysext. This makes the extension compatible regardless of the OS ID string.

### Module Path

The kernel module is placed at `usr/lib/modules/<REAL_KVER>/extra/hailo_pci.ko` where `<REAL_KVER>` is the actual kernel version string (e.g., `6.12.33-production+truenas`), **not** the header package name. On TrueNAS, `/lib` is a symlink to `/usr/lib`, so after sysext merge the module appears at `/lib/modules/<REAL_KVER>/extra/hailo_pci.ko`.

### Module Loading

The `hailo-load.service` uses `insmod` with an absolute path instead of `modprobe`:

```ini
ExecStart=/bin/bash -c '[ -e /sys/module/hailo_pci ] || /sbin/insmod /usr/lib/modules/$(uname -r)/extra/hailo_pci.ko'
```

This is necessary because `/lib/modules/` is on a read-only ZFS dataset on TrueNAS. `depmod` cannot write module dependency files, so `modprobe` cannot find the module. `insmod` bypasses module dependency resolution entirely, loading the `.ko` directly by path.

The `[ -e /sys/module/hailo_pci ]` guard makes the unit idempotent: the PREINIT script normally loads the module before `multi-user.target`, so by the time this service runs the module is already in the kernel and the insmod is skipped. The unit still acts as a backup if PREINIT registration is broken (e.g., midclt failed during install) — and a real insmod failure (version mismatch, missing device) is still surfaced rather than swallowed by `ExecStart=-`.

## TrueNAS Sysext Activation

TrueNAS does **not** use the standard `systemd-sysext merge` path (`/var/lib/extensions/`). Instead, the TrueNAS middleware uses a symlink pattern:

```
/usr/share/truenas/sysext-extensions/hailo.raw  ← the actual file
           ↓ symlink
/run/extensions/hailo.raw                       ← where systemd-sysext looks
           ↓ systemd-sysext refresh
/usr/ overlayfs merge                           ← files appear in /usr/
```

The activation sequence:

1. Place `hailo.raw` at `/usr/share/truenas/sysext-extensions/hailo.raw`
2. Create symlink: `ln -sf /usr/share/truenas/sysext-extensions/hailo.raw /run/extensions/hailo.raw`
3. `systemd-sysext refresh` — merges the sysext via overlayfs
4. `ldconfig` — updates shared library cache

The deactivation sequence:

1. `rm -f /run/extensions/hailo.raw`
2. `systemd-sysext refresh` — unmerges

**Note:** Raw `systemd-sysext merge` does not work on TrueNAS because `/var/lib/extensions/` does not exist.

## Firmware Handling

### Why Firmware Is Not in the Release

Hailo-8 firmware (`hailo8_fw.bin`) is proprietary. Hailo's EULA prohibits redistribution. Including it in GitHub releases would violate the license.

### Install-Time Firmware Download

The install script downloads firmware directly from Hailo's S3 bucket:

```
https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo8/{VERSION}/FW/hailo8_fw.{VERSION}.bin
```

The version is extracted from the release tag (e.g., `v25.10.2.1-hailo4.21.0` → `4.21.0`).

### Firmware Injection into Sysext

Firmware cannot be placed at `/lib/firmware/hailo/` directly because `/lib` is on a separate read-only ZFS dataset from `/usr`. Instead, firmware is injected into the sysext squashfs:

```bash
unsquashfs -d /tmp/hailo-sysext-unpack /tmp/hailo.raw
mkdir -p /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo
cp /tmp/hailo8_fw.bin /tmp/hailo-sysext-unpack/usr/lib/firmware/hailo/hailo8_fw.bin
mksquashfs /tmp/hailo-sysext-unpack /tmp/hailo.raw -noappend -comp zstd
```

When the sysext is merged, firmware appears at `/usr/lib/firmware/hailo/hailo8_fw.bin` → `/lib/firmware/hailo/hailo8_fw.bin` (via symlink), where the kernel firmware loader finds it.

### Firmware at Boot Time

The PREINIT script does **not** download firmware from the network. The backed-up `hailo.raw` on the pool already contains firmware (it was injected at install time). Restoring the backup restores firmware too. This means:

- No network dependency at boot
- No risk of boot failure if Hailo's servers are down
- The firmware version is locked to what was installed

## Persistence Mechanism

TrueNAS updates replace the rootfs, wiping any sysext placed in `/usr/`. The persistence mechanism has two layers:

### Layer 1: Persistent Storage

Config stored on a ZFS data pool (survives OS updates):

```text
/mnt/<pool>/.config/hailo/
├── hailo.raw                ← Backup of the sysext (includes firmware)
├── .hailo-driver-version    ← HailoRT version (informational)
└── hailo-preinit.sh         ← The PREINIT script itself
```

### Layer 2: PREINIT Script

A script registered with TrueNAS via `midclt call initshutdownscript.create` with `"when": "PREINIT"`. Runs on every boot **before the middleware starts**, which means the Hailo device is ready before app containers (e.g., Frigate) launch.

Why PREINIT and not POSTINIT:

- PREINIT runs after ZFS pools are mounted but before the middleware starts apps
- POSTINIT runs after the middleware is up, by which time app containers may already be starting
- The script only uses `zfs`, `cp`, `systemd-sysext`, and `insmod` — all available at PREINIT time
- The timeout is set to 30 seconds (default is 10, which is too tight for the copy + sysext refresh)

The script:

1. Finds backup at `/mnt/<pool>/.config/hailo/hailo.raw` (scans `/mnt/*/.config/hailo/`)
2. Compares SHA256 checksum with installed sysext
3. If different (TrueNAS updated) or missing: copies from backup to `/usr/` (temporarily unlocks ZFS readonly)
4. **Always** activates sysext via symlink + refresh (the `/run/extensions/` symlink is on tmpfs and gone after every reboot)
5. Loads kernel module via `insmod`

The script is idempotent — on a normal reboot where checksums match, it skips the copy but still activates the sysext and loads the module.

### Pool Selection

The install script selects a persistent storage pool in this order:

1. `--persist-path=PATH` — exact path (highest priority)
2. `--pool=NAME` — specific pool name → `/mnt/<NAME>/.config/hailo`
3. **Auto-detect** — first ZFS pool that isn't `boot-pool` → `/mnt/<pool>/.config/hailo`

## Read-Only Filesystem Constraints

TrueNAS has multiple read-only ZFS datasets:

| Path | Writable? | Notes |
| --- | --- | --- |
| `/usr` | No (ZFS readonly) | Can be temporarily unlocked via `zfs set readonly=off` |
| `/lib` | No (separate ZFS dataset) | Symlink to `/usr/lib` but on its own readonly dataset |
| `/lib/modules` | No | Part of the `/lib` dataset |
| `/lib/firmware` | No | Part of the `/lib` dataset |
| `/run/extensions` | Yes (tmpfs) | Where sysext symlinks go |
| `/mnt/<pool>` | Yes | ZFS data pools, persistent |

This is why:

- Firmware goes inside the sysext (merged into `/usr/lib/firmware/` via overlayfs)
- `insmod` is used instead of `modprobe` (can't run `depmod` on read-only `/lib/modules`)
- The install script temporarily unlocks `/usr` to place `hailo.raw`

## Automated Version Monitoring

A single daily workflow (`check-releases.yml`, 06:00 UTC) monitors both upstreams and updates `.github/tracked-versions.json`:

### TrueNAS half

Queries `truenas/scale-build` GitHub tags for the highest stable `TS-*` release. When found:

- Resolves the train name from `download.truenas.com`'s directory listing
- Gates on the matching ISO actually being published (tags can land hours before the ISO)
- Updates `truenas.version` and `truenas.train` in `tracked-versions.json`

This is critical because a new TrueNAS release may ship a different kernel, requiring a recompiled `hailo_pci.ko`.

### HailoRT half

Enumerates tags reachable from `hailort-drivers`'s `hailo8` branch (not `master`, which tracks Hailo-10/15), capped at the version pinned in Frigate's `docker/main/install_hailort.sh` on `dev`. The cap is the gate: HailoRT enforces exact-match between kernel driver and userspace library, and Frigate is the consumer the sysext exists to serve. Updates `hailo.driver` in `tracked-versions.json`.

### Consolidated commit and dispatch

If anything moved, the workflow writes the state file in one commit, runs `sync-build-defaults.sh` to keep `build.yml`'s `workflow_dispatch` defaults aligned, and dispatches a single build with `mark_latest='false'`. Auto-builds publish releases without the "Latest" badge — a human verifies the build on Hailo-8 hardware and promotes it via the GitHub UI.
