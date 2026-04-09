# NVIDIA Tuned Package

A NodeWright package that extends the base `tuned` package with NVIDIA-specific performance profiles for GPU and DGX systems.

## Overview

This package inherits from the base `tuned` package and adds pre-configured tuned profiles optimized for NVIDIA hardware. The profiles are organized by:

- **Common base profiles**: Foundational settings deployed to `/usr/lib/tuned/`
- **OS-specific workload profiles**: Profiles that may vary by OS version
- **Service profiles**: Service-specific settings (EKS, OKE, etc.)

The configmap uses an **intent-based** model where you specify **what** you want (intent + accelerator) rather than a specific profile name. The profile name `nvidia-{accelerator}-{intent}` is constructed automatically.

## Supported Operating Systems

This package requires **tuned >= 2.19**. The following operating systems are supported:

| OS | Version | Status | Notes |
|----|---------|--------|-------|
| **Ubuntu** | 22.04 (Jammy) | ✅ Tested | Uses a min of OS-specific and common profiles |
| **Ubuntu** | 24.04 (Noble) | ✅ Tested | Uses common profiles |
| **Debian** | 11 (Bullseye) | ❌ | Default tuned version is too old (2.15) |
| **Debian** | 12 (Bookworm) | ⚠️ verified tuned package version but not fully tested| Uses common profiles |
| **RHEL** | 9 | ⚠️ verified tuned package version but not fully tested| Uses common profiles |
| **Other** | Any | ⚠️ Fallback | Falls back to `os/common/` profiles (untested, requires tuned >= 2.19) |

### Notes

- **Tested OS versions**: These have been validated with the package and use OS-specific profile configurations
- **Fallback behavior**: For untested OS versions, the package will automatically fall back to the `os/common/` profiles. This fallback is **untested** and requires the system to have **tuned >= 2.19** installed
- **Tuned version requirement**: All systems must have tuned version 2.19 or later. Check your system's tuned version with `tuned --version`
- **OS detection**: The package automatically detects the OS from `/etc/os-release` and selects the appropriate profiles

## Directory Structure

```
profiles/
├── common/                  # Base profiles → /usr/lib/tuned/
│   ├── nvidia-base/
│   └── nvidia-acs-disable/
├── os/
│   ├── common/              # Default workload profiles (fallback for untested OS)
│   │   ├── nvidia-h100-performance/
│   │   ├── nvidia-h100-inference/
│   │   ├── nvidia-h100-multiNodeTraining/
│   │   ├── nvidia-gb200-performance/
│   │   ├── nvidia-gb200-inference/
│   │   └── nvidia-gb200-multiNodeTraining/
│   ├── ubuntu/
│   │   ├── 22.04/          # Mix of symlinks and OS-specific overrides
│   │   └── 24.04/          # Symlinks to os/common/ (override when needed)
│   ├── debian/
│   │   ├── 11/             # Mix of symlinks and OS-specific overrides
│   │   └── 12/             # Symlinks to os/common/ (override when needed)
│   └── rhel/
│       └── 9/              # Symlinks to os/common/ (override when needed)
└── service/
    ├── eks/
    │   ├── tuned.conf.template  # Service template (include= added dynamically)
    │   └── script.sh
    └── oke/
        ├── tuned.conf.template
        ├── script.sh              # Ubuntu GRUB + optional cx8 pci=config_acs
        ├── bootloader.sh        # Ubuntu: merge tuned bootcmdline into GRUB
        ├── cx8-pci-config-acs.grub
        └── hardware/
            ├── bootloader-cx7.conf
            ├── bootloader-cx8.conf
            └── bootloader-infiniband.conf
```

Note: Profiles are stored in `profiles/` (not `root_dir/`) to avoid polluting the host filesystem during package extraction. The prepare scripts explicitly copy profiles to the appropriate tuned directories.

## How It Works

1. **Prepare stage**: `prepare_nvidia_profiles.sh` runs:
   - Reads `intent` and `accelerator` from the configmap
   - Constructs the profile name as `nvidia-{accelerator}-{intent}`
   - Deploys common base profiles to `/usr/lib/tuned/`
   - Detects OS from `/etc/os-release`
   - Copies the appropriate OS-specific workload profiles to `/etc/tuned/`
   - If a `service` is specified, creates service profile with dynamic `include=` pointing to the workload profile
   - For `service: oke`, also appends a hardware-specific `[bootloader]` fragment based on **`NVIDIA_TUNED_OKE_NETWORK`** (see below)

2. **Config stage**: The inherited `tuned` package applies the configured profile

### Profile Name Construction

The profile name is built from the configmap fields:

```
nvidia-{accelerator}-{intent}
```

Examples:
| `accelerator` | `intent` | Constructed Profile |
|---------------|----------|---------------------|
| `h100` | `performance` | `nvidia-h100-performance` |
| `h100` | `inference` | `nvidia-h100-inference` |
| `h100` | `multiNodeTraining` | `nvidia-h100-multiNodeTraining` |
| `gb200` | `performance` | `nvidia-gb200-performance` |
| `gb200` | `inference` | `nvidia-gb200-inference` |
| `gb200` | `multiNodeTraining` | `nvidia-gb200-multiNodeTraining` |

### Inheritance Chain

When you specify `intent: inference`, `accelerator: h100`, and `service: eks`:

```
eks (active profile)
  └── includes: nvidia-h100-inference
        └── includes: nvidia-h100-performance
              └── includes: nvidia-acs-disable
                    └── includes: nvidia-base
```

## Usage

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-tuned-eks
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/dgx: "true"
  packages:
    nvidia-tuned:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-tuned
      version: 0.1.0
      interrupt:
        type: reboot
      configInterrupts:
        intent:
          type: reboot
      env:
        - name: INTERRUPT
          value: "true"
      configMap:
        intent: inference
        accelerator: h100
        service: eks
```

### ConfigMap Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `accelerator` | Yes | — | GPU/accelerator type (e.g., `h100`) |
| `intent` | No | `performance` | Workload intent (e.g., `inference`, `performance`, `multiNodeTraining`) |
| `service` | No | — | Service name (e.g., `eks`). If specified, service profile wraps the workload profile |

## Available Profiles

### Intents (specify in `intent`)

| Intent | Description |
|--------|-------------|
| `performance` | General GPU performance optimization |
| `inference` | Optimized for inference workloads (CPU isolation, hugepages) |
| `multiNodeTraining` | Optimized for distributed training (network buffers, TCP tuning) |

### Accelerators (specify in `accelerator`)

| Accelerator | Description |
|-------------|-------------|
| `h100` | NVIDIA H100 GPU |
| `gb200` | NVIDIA GB200 GPU |

### Services (specify in `service`)

| Service | Description |
|---------|-------------|
| `eks` | EKS-specific settings (MAC address policy for CNI) |
| `oke` | Oracle OKE: kernel cmdline extras for ConnectX-7 / ConnectX-8 / InfiniBand-style naming; Ubuntu GRUB wiring for tuned bootcmdline |

### OKE: `NVIDIA_TUNED_OKE_NETWORK`

When `service: oke`, set this **environment variable** on the package (same value for prepare and runtime). It selects the hardware fragment merged at **prepare** time and drives **cx8** GRUB behavior at **script** start.

| Value | Effect |
|-------|--------|
| `cx7` | Default. No extra `[bootloader]` keys; use workload + NVIDIA profiles only. |
| `cx8` | Adds Oracle HPC-style cx8 cmdline (`iommu=on`, C-states, etc.). On **Ubuntu**, also installs `/etc/default/grub.d/99-nvidia-tuned-oke-cx8-acs.cfg` from `cx8-pci-config-acs.grub` (shape-specific BDF map; replace or skip if wrong for your fleet). |
| `infiniband` | Adds `oci_hpc.rdma_device_names_mode=2` and `oci_hpc.vnic_device_names_mode=1` (same idea as oci-hpc-images `networkdevicenames`). |

Optional:

- **`NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS`**: set to `true` or `1` to skip installing the cx8 `pci=config_acs` grub fragment on Ubuntu (still applies tuned `[bootloader]` keys for cx8).

- **`SKIP_SYSTEM_OPERATIONS`**: when set (any non-empty value, as in Skyhook test/verify flows), OKE Ubuntu scripts skip `update-grub` after writing GRUB drop-ins. If unset, `update-grub` must be on `PATH` (e.g. install `grub-pc` or `grub-efi-amd64` on Ubuntu); otherwise the script fails.

**Ubuntu vs RHEL:** `bootloader.sh` runs only on Ubuntu (`update-grub` + GRUB drop-in). On RHEL and similar, tuned applies `[bootloader]` entries without that helper. The cx8 **pci=config_acs** drop-in is **Ubuntu-only**; on RHEL, supply equivalent boot parameters with your image tooling if required.

### OKE usage example

```yaml
packages:
  nvidia-tuned:
    env:
      - name: NVIDIA_TUNED_OKE_NETWORK
        value: "cx8"
    configMap:
      intent: inference
      accelerator: h100
      service: oke
```

## Adding OS-Specific Overrides

By default, OS version directories contain symlinks to `os/common/`. To add OS-specific settings:

1. Remove the symlink: `rm profiles/os/ubuntu/24.04/nvidia-h100-inference`
2. Create directory: `mkdir profiles/os/ubuntu/24.04/nvidia-h100-inference`
3. Add custom `tuned.conf` with OS-specific settings

## Verification

After deployment, verify the profile is active:

```bash
# List available profiles (should include nvidia-* profiles)
tuned-adm list

# Check active profile
tuned-adm active

# Verify tuning is applied
tuned-adm verify
```

## Inheritance

This package inherits all functionality from the base `tuned` package:

- Multi-distribution support (Ubuntu/Debian, CentOS/RHEL/Amazon Linux)
- Custom profile deployment via configmaps
- Script deployment for complex tuning logic
- Full lifecycle management (install, configure, uninstall)

See the [tuned package README](../tuned/README.md) for complete documentation on all features.

## Version

- **Package Version**: 0.2.4
- **Base Package**: tuned (latest via preprocess.sh)
- **Schema Version**: v1

## Additional documentation
- [NVIDA Grace Performance Tuning Guide](https://docs.nvidia.com/dccpu/grace-perf-tuning-guide/os-settings.html#operating-system-settings)