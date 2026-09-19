# Install Reference

> **Runs as root.** `install.sh` performs privileged operations (writes to a data pool, manages sysexts via `systemd-sysext`, calls `midclt`, loads kernel modules), so it must run as root. Use `sudo` as shown in every example below. `--check` and `--dry-run` also require root; only `--help` runs without it.

## The one line installer (`get.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/hailo8-support/main/get.sh | sudo bash
```

`get.sh` lives on this repo's `main` branch (changed only through reviewed pull requests). It:

1. reads the TrueNAS version (`midclt call system.info`) and the running kernel (`uname -r`), and derives the TrueNAS train (see below);
2. lists this repo's releases and picks the newest build approved for that train and built for that exact kernel and train, the same selection `install.sh` runs on its own;
3. downloads **that release's** `install.sh`, `hailo.raw`, `hailo.raw.sha256` and `firmware.sha256`, verifies the image, and runs the release's own installer on it with the firmware version and sha the release pins. Every installer from r37 on takes a local image this way, so what installs is exactly the approved build.

Options go after `bash -s --`. Anything `get.sh` does not consume is passed to the release's `install.sh`:

| Option | Description |
| --- | --- |
| `--release=TAG` | Use this release as given, skipping the selection (for example a build you are hardware-testing) |
| `--uninstall` | Run the approved release's `uninstall.sh` (and the `restore.sh` beside it) instead of installing |
| `--repo=OWNER/NAME` | Use a fork's releases (also `HAILO_REPO`) |
| `--check`, `--help` | Passed to the release's `install.sh`, which needs no image for them |

`--uninstall`, `--check` and `--help` only need the release's scripts, so on a kernel with no approved build they use the newest approved release **built for your train**. They never fall back to another train's release, not even a grandfathered one: its scripts target that train's install layout. With no approved release of your train they stop and name the waiting hardware tests; `--release=TAG` picks a release explicitly.

## Per-train approval

Nothing untested is installed, on stable or preview (beta) systems. Every build is published as a pre-release with a hardware-test issue, and a release is **approved** for a TrueNAS train when either:

- its notes carry `<!-- verified-train: <train> -->` for that train. `promote.yml` writes it when the build's hardware-test issue is closed as completed; the train is the one the build was made for (from the notes header). A stable build is also promoted to a full release at that point. A preview build stays a pre-release for good; the marker alone approves it; or
- it is a full release with no `verified-train` marker at all: promoted before per-train sign-off, so approved for every train.

The **train** is the major version from 26 on (every 26.x release, betas included, is train `26`) and major.minor before that (`25.10`, `25.04`). A build must also target your exact running kernel, and come from your train (the train guard: the sysext ships userspace built against that train's base system). A stable system never installs a preview (beta) build. With no approved build for your kernel the installer stops and names the hardware-test issue that is waiting; see [troubleshooting](troubleshooting.md#no-approved-build-for-your-kernel-yet).

## Installing a Specific Version

Release tags encode the kernel the build targets: `k<kernel>-hailo<driver>-r<run>` (e.g., `k6.12.91-hailo4.21.0-r41`). Releases published before the kernel-keyed migration keep their older `v<truenas>-hailo<driver>` tags (e.g., `v25.10.2.1-hailo4.21.0`); both install the same way. The README supported versions table maps TrueNAS versions to the release serving them.

To install a specific release, pin it with `--release` (no selection, so this also installs a build that is not approved yet, for example to hardware-test it):

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/hailo8-support/main/get.sh | sudo bash -s -- --release=k6.12.91-hailo4.21.0-r41
```

Or download a release's files and install its `hailo.raw` by hand. A local image needs the HailoRT version (from the tag) and the release's `firmware.sha256`:

```bash
TAG=k6.12.91-hailo4.21.0-r41
BASE=https://github.com/truenas-community-sysexts/hailo8-support/releases/download/$TAG
for f in hailo.raw hailo.raw.sha256 install.sh firmware.sha256; do curl -fsSL "$BASE/$f" -o "$f"; done
sha256sum -c hailo.raw.sha256
sudo bash install.sh ./hailo.raw --firmware-version=4.21.0 --expected-firmware-sha="$(cat firmware.sha256)"
```

> **Warning:** Using a `hailo.raw` built for a different kernel will fail to load
> the kernel module. The module is compiled against exact kernel headers - a kernel mismatch
> means `insmod` will refuse to load it. Always use the release matching your running kernel
> (`uname -r`); the installer checks this before touching the system.

## Install Options

| Option | Description |
| --- | --- |
| `--repo=OWNER/NAME` | GitHub repo for releases (default: `truenas-community-sysexts/hailo8-support`). Also settable via `HAILO_REPO` env var. |
| `--firmware-version=X.Y.Z` | With a local `hailo.raw`: the HailoRT version whose firmware to download |
| `--expected-firmware-sha=HEX` | With a local `hailo.raw`: the expected sha256 of that firmware (the release's `firmware.sha256`) |
| `--pool=NAME` | ZFS pool for persistent config (e.g., `fast`) |
| `--persist-path=PATH` | Persistent config directory. Must be `/mnt/<pool>/.config/hailo` (the exact location the boot-time PREINIT script scans). Prefer `--pool`, which builds this path for you. |
| `--check` | Probe an existing install (read-only) and report status |
| `--dry-run` | Validate everything (downloads, checksums, network) without modifying the system |
| `--help` | Show usage help |

## Probing and Validating

**`--check`** performs a read-only probe of an existing install: device node, kernel module, sysext file/merge state, persistent config + backup, PREINIT script + middleware registration, kernel-version match, and PREINIT boot result. Each failure includes a one-line hint. Exits 1 if any check fails.

```bash
# Probe an existing install
sudo ./install.sh --check
# Or via curl
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/hailo8-support/main/get.sh | sudo bash -s -- --check
```

**`--dry-run`** performs every read/network/validation step (release lookup, sha256 verify, firmware download, squashfs unpack/repack) but skips every command that mutates the running system. Each skipped mutation is logged as `[dry-run] would: <command>`.

`--check` and `--dry-run` are mutually exclusive.

## What the Install Script Does

1. **Downloads `hailo.raw`** from the newest release approved for your TrueNAS train and built for your running kernel (or uses a local file, which is what `get.sh` hands it)
2. **Verifies the checksum** (SHA256)
3. **Downloads Hailo-8 firmware** directly from Hailo's S3 servers (not redistributed by this project)
4. **Verifies firmware SHA256** against the hash published as the release's `firmware.sha256` asset
5. **Injects firmware** into the sysext squashfs (unpacks, adds firmware, repacks)
6. **Installs the sysext** to `/mnt/<pool>/.config/hailo/hailo.raw` on a data pool
7. **Activates the sysext** in place via TrueNAS's symlink + refresh pattern
8. **Loads the kernel module** via `insmod` (skipped when `hailo_pci` is already loaded, as on a reinstall: the new module loads at the next reboot)
9. **Sets up persistence** (see below)

## Persistence

TrueNAS updates replace the rootfs, which wipes `/usr/` and any installed sysext. The install script sets up automatic recovery:

### Recovery Process

1. **Image on the data pool**: The sysext (with firmware already injected) is written to a persistent ZFS pool, and that is the copy `/run/extensions/` activates
2. **PREINIT script**: Registered with TrueNAS middleware, runs on every boot before apps start
3. On boot, the script re-points `/run/extensions/hailo.raw` at the data-pool image and runs `systemd-sysext refresh`. Because the image lives on the data pool (not `/usr`), a TrueNAS update cannot wipe it, so the same path works on every boot
4. No network access is needed at boot - firmware is already inside the sysext image

### Persistent Storage Layout

```text
/mnt/<pool>/.config/hailo/
├── hailo.raw                ← Sysext image (includes firmware), activated in place
├── .hailo-driver-version    ← HailoRT version (informational)
├── .hailo-repo              ← Source GitHub repo (used by preinit for error messages)
└── hailo-preinit.sh         ← Boot script (extracted from hailo.raw, registered as PREINIT)
```

### Pool Selection

The install script selects a pool in this order:

1. `--persist-path=PATH` - use this exact path (highest priority)
2. `--pool=NAME` - use `/mnt/<NAME>/.config/hailo`
3. **Auto-detect** - first ZFS pool that isn't `boot-pool`

The PREINIT script finds the config at boot by scanning `/mnt/*/.config/hailo/`, so it works even if the pool name changes.

## Device Permissions

The sysext ships a udev rule (`51-hailo-udev.rules`) that sets `/dev/hailo*` to mode `0666` (world read/write). This is intentional: Docker containers typically run as non-root and need direct device access without extra group configuration. On a single-user TrueNAS box this is fine.

If you want tighter permissions, edit the rule in the sysext to use `GROUP="video"` with `MODE="0660"` and add your container user to the `video` group. Note that the sysext is a squashfs image, so you'd need to unpack, edit, and repack it (or patch the rule in the build workflow for a permanent change).

## Scripts Reference

| Script | Purpose |
| --- | --- |
| `get.sh` | One line installer served from `main`: picks the approved release and runs that release's `install.sh` (or `uninstall.sh`) |
| `scripts/install.sh` | Downloads release, fetches firmware, injects into sysext, installs, sets up persistence |
| `scripts/uninstall.sh` | Discoverable alias - runs `restore.sh` (fetched from the release approved for the train when piped from curl) |
| `scripts/restore.sh` | Uninstalls sysext, deregisters init script, cleans up persistent storage |
| `scripts/hailo-preinit.sh` | Boot-time script - activates sysext before apps start (bundled inside hailo.raw at `/usr/lib/hailo/`) |
