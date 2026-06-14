# Changelog

Changes since the initial project baseline, organized by area.

## Install / Restore Scripts

- **Custom source repository.** `install.sh` accepts `--repo=OWNER/NAME` and the `HAILO_REPO` environment variable, so installs from a fork pull artifacts from the fork's releases instead of upstream. The selected repo is recorded in `${PERSIST_DIR}/.hailo-repo`.
- **Branch-aware preinit error messages.** `hailo-preinit.sh` reads `.hailo-repo` and points kernel-mismatch error output at the source repo's releases page.
- **Loud failure on missing HailoRT version.** Install/preinit now exit with a clear error if the HailoRT version cannot be determined, instead of silently proceeding with bad state.
- **Bounded curl downloads.** `install.sh` caps every release/firmware/install-script download with `--max-time`, so a stalled connection fails fast instead of hanging the install indefinitely.
- **`install.sh --check`.** Read-only probe of an existing install: device node, kernel module, sysext file/merge state, persistent config + backup, PREINIT script + middleware registration, kernel-version match, and PREINIT boot result. Each failure includes a one-line hint. Exits 1 if any check fails.
- **`install.sh --dry-run`.** Performs every read/network/validation step (release lookup, sha256 verify, firmware download, squashfs unpack/repack) but skips every command that mutates the running system. Each skipped mutation is logged as `[dry-run] would: <command>`. Mutually exclusive with `--check`.
- **`/tmp/hailo.raw` self-copy guard.** Prevents `install.sh /tmp/hailo.raw` from colliding with the installer's staging path.
- **`midclt` lookup refused on transient error.** Distinguishes "not registered" from "lookup error" and aborts on the latter rather than guessing.
- **Firmware sha256 verification.** `install.sh` verifies downloaded Hailo-8 firmware against the sha256 published in `.github/tracked-versions.json`. Hard-fails on mismatch or missing hash.
- **`scripts/uninstall.sh` wrapper.** Discoverable alias around `restore.sh` for users who search for "uninstall" rather than "restore".

## Sysext Activation on TrueNAS

- **`systemd-sysext unmerge` before ZFS writes.** `install.sh` and `restore.sh` now `unmerge` the sysext (rather than `refresh`) before unlocking `/usr`, so the overlay does not block the remount. Without this, repeated installs/restores would intermittently fail when another sysext (e.g. NVIDIA) is active.
- **PREINIT script bundled in `hailo.raw`.** `scripts/hailo-preinit.sh` ships inside the sysext at `/usr/lib/hailo/hailo-preinit.sh`. `install.sh` extracts it during the firmware-injection unsquashfs/mksquashfs cycle. Replaces the prior arrangement where `install.sh` carried an ~130-line heredoc copy.
- **`/usr` readonly restored on signal.** All scripts install a `trap restore_usr_readonly EXIT INT TERM` so a SIGINT/SIGTERM between `zfs set readonly=off` and the matching `readonly=on` does not leave `/usr` writable until reboot.
- **Empty-SHA256 defensive reinstall in PREINIT.** If `sha256sum` returns an empty hash for either the installed sysext or the backup, `hailo-preinit.sh` now reinstalls from backup rather than treating two empty strings as a match.
- **`hailo-load.service` idempotent.** The unit guards on `[ -e /sys/module/hailo_pci ]` so it no-ops when PREINIT already loaded the module. Restart limits (`StartLimitBurst=3`, `StartLimitIntervalSec=60`) cap restart loops on permanent failures.

## Automated Workflows

- **Single check workflow + single state file.** Replaced two scheduled workflows (`check-truenas-release.yml`, `check-hailo-release.yml`) and three root-level state files (`version`, `train`, `.hailo-driver-version`) with one workflow (`.github/workflows/check-releases.yml`) and one CI-state file (`.github/tracked-versions.json`).
- **Daily schedule.** The unified check runs daily at 06:00 UTC instead of weekly.
- **TrueNAS ISO availability gate.** Only bumps the tracked TrueNAS version once the matching ISO is published at `download.truenas.com`.
- **Auto-resolved train name.** Picks the highest stable scale-build tag and resolves the train from `download.truenas.com`'s directory listing. New trains are picked up automatically.
- **Frigate-pin gate on Hailo bumps.** Caps the candidate version at the `hailo_version` pinned in Frigate's `docker/main/install_hailort.sh` on the `dev` branch.
- **`mark_latest` input on `build.yml`.** Auto-built releases publish without claiming "Latest"; a human promotes after hardware verification.
- **Build runner resolved per-build.** `runs-on:` is resolved from TrueNAS's Debian release via `.github/scripts/resolve-runner.sh`, no longer hardcoded.
- **Auto-synced `workflow_dispatch` defaults.** Each auto-bump commit rewrites `build.yml`'s `workflow_dispatch` defaults via `.github/scripts/sync-build-defaults.sh`.
- **Lint workflow.** `shellcheck --severity=warning` on all shell scripts, `actionlint` on workflow YAML, and `tracked-versions.json` shape validation.
- **Build-time smoke test.** Before publishing, `build.yml` asserts required files exist, ELF binaries are real, and `hailo_pci.ko`'s vermagic matches the target kernel.
- **`find_vma` mmap-lock patch on the pinned driver.** `build.yml` applies `patches/*.patch` to the cloned hailort-drivers tree before compiling, via the idempotent `.github/scripts/apply-driver-patches.sh`. The first patch re-applies Hailo's own upstream commit `8edb23b` (`mmap_read_lock`/`mmap_read_unlock` around `find_vma` in `hailo_vdma_buffer_map`), which 4.21.0 — the Frigate-pinned version we build — predates, and which the hailo8 branch reverted in 4.23.0. Without it, Linux 6.12+ trips a `mmap_assert_locked()` WARN (`rwsem.h:80`) on every DMA-map ioctl, which can escalate to an oops during inference. A follow-up build step refuses to publish if `find_vma(current->mm,…)` is not guarded by `mmap_read_lock`, for any driver version.
- **Richer release notes.** Includes real kernel version, runner image, build commit SHA, and Frigate compatibility link.
- **Firmware sha256 captured on Hailo bumps.** `check-releases.yml` computes and records the sha256 in the same commit as the version bump.
- **Dependabot for `github-actions`.** Weekly PRs to bump action versions.
