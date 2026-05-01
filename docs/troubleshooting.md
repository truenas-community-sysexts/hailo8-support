# Troubleshooting

## Kernel version mismatch after a TrueNAS update

After TrueNAS updates the underlying kernel, the boot-time PREINIT script
logs the following and `/dev/hailo0` will not initialize:

```
[hailo-preinit] ERROR: Kernel version mismatch — running <new-kver> but sysext has module for <old-kver>
[hailo-preinit] ERROR: TrueNAS was likely updated. Download a new hailo.raw release matching <new-kver>
[hailo-preinit] ERROR: Visit https://github.com/<repo>/releases
```

This is **expected** behavior on a TrueNAS upgrade — not a bug. The Hailo
kernel module is compiled against an exact kernel version, so the previous
sysext is no longer compatible.

### Recovery

1. Check the running kernel:

   ```bash
   uname -r
   ```

2. Visit the releases page printed in the error message.

3. Find the release whose tag matches your TrueNAS version
   (`v<truenas>-hailo<driver>`). The release notes record the kernel
   version it was built against.

4. If a matching release exists, re-run the installer:

   ```bash
   curl -fsSL https://github.com/andretakagi/truenas-hailo/releases/latest/download/install.sh \
     | sudo bash -s -- --repo=andretakagi/truenas-hailo
   ```

   The installer downloads the matching `hailo.raw` and replaces the
   stale sysext on the persistent pool. The next boot succeeds.

5. If no matching release exists yet, the daily auto-build workflow on
   this fork picks up new TrueNAS versions within ~24 hours of the ISO
   being published at `download.truenas.com`. Wait for the build to
   land, then repeat step 4. If a build is overdue, open an issue.

### Why this can't be fixed automatically

The PREINIT script can detect the mismatch but cannot fix it on its own:
downloading a new `hailo.raw` requires network access, and PREINIT runs
before the network stack is reliably up. Recovery is intentionally a
human step.
