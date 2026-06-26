# Hailo-8 AI Accelerator Sysext for TrueNAS

A systemd-sysext package that adds [Hailo-8](https://hailo.ai/) AI accelerator support to TrueNAS. Primarily useful for running [Frigate NVR](https://frigate.video/) with hardware-accelerated AI object detection.

## Documentation

| Doc | Contents |
| --- | --- |
| [Quick Start](#quick-start) | Install, verify, uninstall |
| [docs/install.md](docs/install.md) | Install options, specific versions, persistence, scripts reference |
| [docs/build.md](docs/build.md) | Build process, firmware handling, automated updates, custom builds |
| [docs/architecture.md](docs/architecture.md) | Deep technical reference — sysext structure, read-only constraints |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Recovery from kernel-mismatch errors after TrueNAS upgrades |

## What's Included

The `hailo.raw` sysext contains:

| Component | Description |
| --- | --- |
| `hailo_pci.ko` | PCIe kernel module (compiled for exact TrueNAS kernel) |
| `libhailort.so` | HailoRT runtime library |
| `hailortcli` | HailoRT command-line tool |
| `hailo-load.service` | Systemd service for automatic module loading |
| `51-hailo-udev.rules` | Udev rules for `/dev/hailo*` permissions |

> **Note:** Hailo-8 firmware (`hailo8_fw.bin`) is **not** included in the release.
> It is proprietary (Hailo's EULA prohibits redistribution) and is downloaded
> directly from Hailo's servers during installation.

## Compatibility

| Device | Supported | Notes |
| --- | --- | --- |
| Hailo-8  | Yes | Primary target |
| Hailo-8L | Yes | Same driver / kernel module; Frigate uses the `hailo8l` detector type for both |
| Hailo-10 | No | Lives on `master` of [`hailort-drivers`](https://github.com/hailo-ai/hailort-drivers) (5.x line) — not built by this project |
| Hailo-15 | No | Same — not built by this project |

This sysext builds the `hailo_pci` kernel module from the **`hailo8` branch** of [`hailort-drivers`](https://github.com/hailo-ai/hailort-drivers). The `master` branch tracks a different driver line for Hailo-10 / Hailo-15 that does not support Hailo-8 silicon.

## Quick Start

### Supported TrueNAS versions

The sysext is built per TrueNAS version: the kernel module must match your exact running kernel. Builds come in two channels:

- **Stable** — current TrueNAS SCALE 25.x train. Published as the **Latest** release.
- **Preview** — TrueNAS SCALE 26 beta (e.g. `26.0.0-BETA.2`). Published as a **pre-release** and **experimental** (not for production).

You don't pick a build by hand. The installer detects your running TrueNAS version (`midclt call system.info`) and downloads the matching sysext automatically: a 25.x box gets the stable build, a 26 beta box gets the matching preview build. Because previews are GitHub pre-releases, the [releases page](../../releases) lists both the **Latest** stable release and the **Pre-release** previews.

If there is no build yet for your exact version (e.g. a brand-new point release), the installer says so and lists what is available; check back after the daily build, or [build it yourself](docs/build.md).

### Prerequisites

- A supported TrueNAS SCALE version (25.x stable or 26 beta) on amd64 — see [Supported TrueNAS versions](#supported-truenas-versions) above; the installer auto-detects yours
- Hailo-8 PCIe AI accelerator installed and visible (`lspci | grep Hailo`)
- Root/sudo access
- Internet access (to download the release and firmware)

### Install

Auto-detects your TrueNAS version, downloads the matching release, fetches firmware from Hailo, and sets up persistence:

```bash
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/latest/download/install.sh | sudo bash
```

With an explicit pool for persistence:

```bash
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/latest/download/install.sh -o install.sh
sudo bash install.sh --pool=fast
```

> **Version matching:** Each release is built for a specific TrueNAS kernel. The install script
> auto-detects your version and downloads the correct release. See [docs/install.md](docs/install.md)
> for installing a specific version or troubleshooting.

### Verify

Run the built-in status probe:

```bash
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/latest/download/install.sh | sudo bash -s -- --check
```

Or check manually:

```bash
ls -la /dev/hailo*                      # Device detected
lsmod | grep hailo                      # Module loaded
sudo hailortcli fw-control identify     # Firmware responding
```

### Uninstall

```bash
curl -fsSL https://github.com/truenas-community-sysexts/hailo8-support/releases/latest/download/uninstall.sh | sudo bash
```

## Using with Frigate

### 1. Pass Through the Device

In TrueNAS Apps, edit your Frigate app and add the device mapping:

```text
/dev/hailo0:/dev/hailo0
```

### 2. Configure Frigate Detectors

In your Frigate `config.yaml`:

```yaml
detectors:
  hailo8l:
    type: hailo8l    # Use hailo8l for both Hailo-8 and Hailo-8L
    device: PCIe
    model:
      width: 640
      height: 640
      input_tensor: nhwc
      input_pixel_format: rgb
      input_dtype: int
      model_type: yolo-generic
```

> **Note:** Frigate uses `hailo8l` as the detector type for **both** Hailo-8 and Hailo-8L devices.

For a larger model (Hailo-8 has more capacity than 8L), add a `path` to the model section:

```yaml
model:
  path: https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.17.0/hailo8/yolov8m.hef
```

## Important Notes

- The kernel module must match the exact TrueNAS kernel version. If you update TrueNAS, you need a matching sysext build — see [docs/troubleshooting.md](docs/troubleshooting.md#kernel-version-mismatch-after-a-truenas-update) for recovery steps.
- Secure Boot: The unsigned kernel module may require disabling Secure Boot.
- If firmware download fails during installation, the script aborts — the sysext will not be installed without firmware.

## License

MIT — see [LICENSE](LICENSE).

The Hailo-8 firmware downloaded during installation is proprietary and subject to Hailo's EULA.

## Credits

Hailo-8 driver source: [hailo-ai/hailort-drivers](https://github.com/hailo-ai/hailort-drivers) and [hailo-ai/hailort](https://github.com/hailo-ai/hailort).

## About This Project

This project was developed with the assistance of AI (Claude by Anthropic) via Claude Code. A human provided direction, reviewed outputs, and made decisions, but the implementation was AI-assisted.
