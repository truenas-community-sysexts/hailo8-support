# Troubleshooting

## Kernel version mismatch after a TrueNAS update

After TrueNAS updates the underlying kernel, the boot-time PREINIT script
logs the following and `/dev/hailo0` will not initialize:

```
[hailo-preinit] ERROR: Kernel version mismatch - running <new-kver> but sysext has module for <old-kver>
[hailo-preinit] ERROR: TrueNAS was likely updated. Download a new hailo.raw release matching <new-kver>
[hailo-preinit] ERROR: Visit https://github.com/<repo>/releases
```

This is **expected** behavior on a TrueNAS upgrade - not a bug. The Hailo
kernel module is compiled against an exact kernel version, so the previous
sysext is no longer compatible.

### Recovery

1. Check the running kernel:

   ```bash
   uname -r
   ```

2. Visit the releases page printed in the error message.

3. Find the release whose tag matches your running kernel
   (`k<kernel>-hailo<driver>-r<run>`, e.g. `k6.12.91-...` for kernel
   `6.12.91-production+truenas`). Older releases use `v<truenas>-...` tags;
   either way the release notes record the exact kernel the build targets.

4. If a matching release exists, re-run the installer:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/hailo8-support/main/get.sh \
     | sudo bash
   ```

   The installer downloads the matching `hailo.raw` and replaces the
   stale sysext on the persistent pool. The next boot succeeds.

5. If no matching release exists yet, the daily auto-build workflow
   picks up new TrueNAS versions within ~24 hours of the ISO being
   published at `download.truenas.com`. Wait for the build to land,
   then repeat step 4. If a build is overdue, open an issue.

### Why this can't be fixed automatically

The PREINIT script can detect the mismatch but cannot fix it on its own:
downloading a new `hailo.raw` requires network access, and PREINIT runs
before the network stack is reliably up. Recovery is intentionally a
human step.

## No approved build for your kernel yet

The installer only installs a build that a hardware test approved for your
TrueNAS train (see [Per-train approval](install.md#per-train-approval)). A
new build is a pre-release with an open hardware-test issue until someone
verifies it on real hardware, so for a while the installer stops with:

```
No stable release found for kernel <kver> (TrueNAS <version>).
Only a build a hardware test approved for TrueNAS train <train> is installed;
nothing unapproved is, on stable or preview systems.
A build for this kernel is awaiting hardware-test sign-off for train <train>.
It installs once its test issue is closed as completed:
  <tag>: https://github.com/<repo>/issues?q=...
```

The link opens that build's hardware-test issue. It is the one step left:
once a tester closes it as completed, the same one-liner installs the
build. If you have the hardware, the issue body lists the exact test steps;
testing it yourself and reporting back is the fastest way to get it
approved. Installing it before then is possible by hand (the issue's
steps), but it is untested on your train.

## Reinstalling while `hailo_pci` is loaded

Re-running `install.sh` on the same kernel (for example a newer build for
the kernel you are already running) finds the module loaded and prints:

```
hailo_pci already loaded, skipping insmod: this build's module loads at the next reboot
```

The installer never unloads a live module, so the loaded one stays in use
until you reboot. If the new build changes the HailoRT version, the old
module and firmware also stay active until then, so `hailortcli` can fail
with a driver version mismatch or show the old firmware version. Reboot to
switch over.

## Unused boot-pool copy after upgrading from an older release

Releases before in-place activation copied the image to the boot pool at
`/usr/share/truenas/sysext-extensions/hailo.raw` and linked
`/run/extensions/hailo.raw` to it. Current releases activate the image on
the data pool instead, so after an upgrade the old copy (a few MB) is left
behind and `install.sh --check` reports:

```
i Unused boot-pool copy /usr/share/truenas/sysext-extensions/hailo.raw left by an older install (informational)
```

It is not a warning or a failure. Nothing reads the file once
`/run/extensions/hailo.raw` points at the data pool, and the next TrueNAS
update removes it (the update installs a fresh boot environment). The
installer leaves it alone on purpose: deleting it means making `/usr`
writable, which in-place activation exists to avoid.

### Optional manual removal

Only if you want the space back before the next update. Run these blocks in
bash (start one with `bash` if your login shell is zsh), so the `#` notes
are read as comments. First confirm the copy is unused:

```bash
readlink /run/extensions/hailo.raw   # must print /mnt/<pool>/.config/hailo/hailo.raw
```

The removal briefly unmerges every sysext (Hailo, and NVIDIA if installed),
the same as a reinstall does, so stop apps that use them first (for example
Frigate). Then:

```bash
sudo systemd-sysext unmerge                   # /usr is the plain ZFS dataset again
USR_DATASET=$(sudo zfs list -H -o name /usr)
echo "$USR_DATASET"                           # expect boot-pool/ROOT/<version>/usr
sudo zfs set readonly=off "$USR_DATASET"
sudo rm -f /usr/share/truenas/sysext-extensions/hailo.raw
sudo zfs set readonly=on "$USR_DATASET"
sudo systemd-sysext refresh                   # re-merge every sysext in /run/extensions
sudo ldconfig
```

The unmerge comes first because a sysext overlay mounted on `/usr` blocks
the `readonly=off` remount (older installers unmerged first for the same
reason). If the dataset is not the expected one, or a step fails, stop
there: run `sudo zfs set readonly=on "$USR_DATASET"` (if it was set off) and
`sudo systemd-sysext refresh`, then start your apps again. The leftover file
itself is harmless.
