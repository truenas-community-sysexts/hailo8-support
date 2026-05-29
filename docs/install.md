# Install Reference

> **Runs as root.** `install.sh` performs privileged operations (toggles ZFS `readonly`, writes under `/usr`, calls `midclt`, loads kernel modules), so it must run as root. Use `sudo` as shown in every example below. `--check` and `--dry-run` also require root; only `--help` runs without it.

## Installing a Specific Version

Release tags encode both versions: `v<truenas>-hailo<driver>` (e.g., `v25.10.2.1-hailo4.21.0`).

To install from a specific release:

```bash
# Download install.sh from a specific release tag
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/download/v25.10.2.1-hailo4.21.0/install.sh | sudo bash
```

Or download `hailo.raw` manually and install it:

```bash
# Download hailo.raw from a specific release
curl -fSL https://github.com/truenas-community-sysexts/hailo8-support/releases/download/v25.10.2.1-hailo4.21.0/hailo.raw -o /tmp/hailo.raw
sudo bash install.sh /tmp/hailo.raw
```

> **Warning:** Using a `hailo.raw` built for a different TrueNAS version will fail to load
> the kernel module. The module is compiled against exact kernel headers — a version mismatch
> means `insmod` will refuse to load it. Always use the release matching your TrueNAS version.

## Install Options

| Option | Description |
| --- | --- |
| `--repo=OWNER/NAME` | GitHub repo for releases (default: `truenas-community-sysexts/hailo8-support`). Also settable via `HAILO_REPO` env var. |
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
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/latest/download/install.sh | sudo bash -s -- --check
```

**`--dry-run`** performs every read/network/validation step (release lookup, sha256 verify, firmware download, squashfs unpack/repack) but skips every command that mutates the running system. Each skipped mutation is logged as `[dry-run] would: <command>`.

`--check` and `--dry-run` are mutually exclusive.

## What the Install Script Does

1. **Downloads `hailo.raw`** from the GitHub release matching your TrueNAS version (or uses a local file)
2. **Verifies the checksum** (SHA256)
3. **Downloads Hailo-8 firmware** directly from Hailo's S3 servers (not redistributed by this project)
4. **Verifies firmware SHA256** against the hash published in `.github/tracked-versions.json`
5. **Injects firmware** into the sysext squashfs (unpacks, adds firmware, repacks)
6. **Installs the sysext** to `/usr/share/truenas/sysext-extensions/hailo.raw`
7. **Activates the sysext** via TrueNAS's symlink + refresh pattern
8. **Loads the kernel module** via `insmod`
9. **Sets up persistence** (see below)

## Persistence

TrueNAS updates replace the rootfs, which wipes `/usr/` and any installed sysext. The install script sets up automatic recovery:

### Recovery Process

1. **Backup**: The sysext (with firmware already injected) is copied to a persistent ZFS pool
2. **PREINIT script**: Registered with TrueNAS middleware, runs on every boot before apps start
3. On boot, the script compares checksums — if the installed sysext differs from the backup (indicating a TrueNAS update) or is missing, it reinstalls from the backup
4. No network access is needed at boot — firmware is already inside the backed-up sysext

### Persistent Storage Layout

```text
/mnt/<pool>/.config/hailo/
├── hailo.raw                ← Sysext backup (includes firmware)
├── .hailo-driver-version    ← HailoRT version (informational)
├── .hailo-repo              ← Source GitHub repo (used by preinit for error messages)
└── hailo-preinit.sh         ← Boot script (extracted from hailo.raw, registered as PREINIT)
```

### Pool Selection

The install script selects a pool in this order:

1. `--persist-path=PATH` — use this exact path (highest priority)
2. `--pool=NAME` — use `/mnt/<NAME>/.config/hailo`
3. **Auto-detect** — first ZFS pool that isn't `boot-pool`

The PREINIT script finds the config at boot by scanning `/mnt/*/.config/hailo/`, so it works even if the pool name changes.

## Device Permissions

The sysext ships a udev rule (`51-hailo-udev.rules`) that sets `/dev/hailo*` to mode `0666` (world read/write). This is intentional: Docker containers typically run as non-root and need direct device access without extra group configuration. On a single-user TrueNAS box this is fine.

If you want tighter permissions, edit the rule in the sysext to use `GROUP="video"` with `MODE="0660"` and add your container user to the `video` group. Note that the sysext is a squashfs image, so you'd need to unpack, edit, and repack it (or patch the rule in the build workflow for a permanent change).

## Scripts Reference

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Downloads release, fetches firmware, injects into sysext, installs, sets up persistence |
| `scripts/uninstall.sh` | Discoverable alias — downloads and runs `restore.sh` |
| `scripts/restore.sh` | Uninstalls sysext, deregisters init script, cleans up persistent storage |
| `scripts/hailo-preinit.sh` | Boot-time script — activates sysext before apps start (bundled inside hailo.raw at `/usr/lib/hailo/`) |
