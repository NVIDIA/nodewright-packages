# NVIDIA Tuned Package

A NodeWright package that extends the base `tuned` package with NVIDIA-specific performance profiles for GPU and DGX systems.

## Overview

This package inherits from the base `tuned` package and adds pre-configured tuned profiles optimized for NVIDIA hardware. The profiles are organized by:

- **Common base profiles**: Foundational settings deployed to the tuned profiles dir (`/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)
- **OS-specific workload profiles**: Profiles that may vary by OS version
- **Service profiles**: Service-specific settings (eks, GCP, etc.)

The configmap uses an **intent-based** model where you specify **what** you want (intent + accelerator) rather than a specific profile name. The profile name `nvidia-{accelerator}-{intent}` is constructed automatically. When `accelerator=generic`, the self-contained `nvidia-generic` profile is used instead, providing safe baseline tuning for any NVIDIA GPU without requiring accelerator-specific or intent-specific configuration.

## Supported Operating Systems

This package requires **tuned >= 2.19**. The following operating systems are supported:

> **vr200:** The `vr200` accelerator is supported on **Ubuntu 26.04 only**. Its
> profiles live under `profiles/os/ubuntu/26.04/`. The base profiles keep the
> reboot-requiring `[bootloader]` tuning (same as gb200); with `service=bcm`, vr200
> uses a bootloader-free profile chain (`nvidia-vr200-noreboot-base`) so the tuning
> applies without a reboot. There is no `service=eks` vr200 profile yet.

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

```text
profiles/
├── common/                  # Base profiles → tuned profiles dir
│   ├── nvidia-base/
│   └── nvidia-acs-disable/
├── os/
│   ├── common/              # Default workload profiles (fallback for untested OS)
│   │   ├── nvidia-generic/             # Self-contained baseline (accelerator=generic)
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
    ├── common/                  # Shared helpers copied into every service's final profile dir
    │   ├── mac-address-policy.sh
    │   └── bootloader.sh
    ├── eks/
    │   ├── tuned.conf.template  # Service template (include= added dynamically)
    │   ├── script.sh            # Sources common/mac-address-policy.sh, invokes common/bootloader.sh
    │   ├── nvidia-h100-inference.conf   # AWS-compatible inference override
    │   └── nvidia-gb200-inference.conf
    ├── aks/
    │   ├── tuned.conf.template
    │   ├── script.sh            # Sources common/mac-address-policy.sh, invokes common/bootloader.sh
    │   └── nvidia-h100-inference.conf   # AKS-compatible inference override (drops kernel-6.8 EEVDF sysctls)
    └── oci/
        ├── tuned.conf.template  # RDMA IPv6 defaults for OCI's IPv6/SLAAC RoCE fabric
        ├── script.sh            # Re-enables IPv6 on existing mlx5 RDMA VFs
        ├── nvidia-gb300-performance.conf   # Re-roots gb300 onto the bootloader-free base
        ├── nccl-topo-gb300.xml  # Installed to ${TOPO_PATH} by the write-nccl-topo config step
        ├── pcie-acs-gb300.enabled          # Opts gb300 in to the configure-pcie-acs config step
        └── rdma-vfs-ready-gb300/           # Installed by the install-rdma-vfs-ready config step
            ├── rdma-vfs-ready.service
            └── wait-rdma-vfs.sh
```

Note: Profiles are stored in `profiles/` (not `root_dir/`) to avoid polluting the host filesystem during package extraction. The prepare scripts explicitly copy profiles to the appropriate tuned directories.

## How It Works

1. **Prepare stage**: `prepare_nvidia_profiles.sh` runs:
   - Reads `intent` and `accelerator` from the configmap
   - Constructs the profile name as `nvidia-{accelerator}-{intent}`
   - Deploys common base profiles to the resolved tuned profiles dir
   - Detects OS from `/etc/os-release`
   - Copies the appropriate OS-specific workload profiles to the resolved tuned profiles dir (`/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)
   - If a `service` is specified, creates service profile with dynamic `include=` pointing to the workload profile

2. **Host setup steps**: three steps run between `prepare` and the profile apply. Each
   resolves a bundled asset from the configured `service` and `accelerator` and is a
   no-op when that pair ships nothing, so they cost nothing for pairs that do not use
   them:
   - `write-nccl-topo` installs `profiles/service/{service}/nccl-topo-{accelerator}.xml`
     to `${TOPO_PATH}`
   - `install-rdma-vfs-ready` installs and enables the systemd unit in
     `profiles/service/{service}/rdma-vfs-ready-{accelerator}/`
   - `configure-pcie-acs` runs the node's `rdma_topo` tool when
     `profiles/service/{service}/pcie-acs-{accelerator}.enabled` is present

3. **Config stage**: The inherited `tuned` package applies the configured profile

### Profile Name Construction

The profile name is built from the configmap fields:

```
nvidia-{accelerator}-{intent}
```

Examples:
| `accelerator` | `intent` | Constructed Profile |
|---------------|----------|---------------------|
| `generic` | *(ignored)* | `nvidia-generic` |
| `h100` | `performance` | `nvidia-h100-performance` |
| `h100` | `inference` | `nvidia-h100-inference` |
| `h100` | `multiNodeTraining` | `nvidia-h100-multiNodeTraining` |
| `gb200` | `performance` | `nvidia-gb200-performance` |
| `gb200` | `inference` | `nvidia-gb200-inference` |
| `gb200` | `multiNodeTraining` | `nvidia-gb200-multiNodeTraining` |
| `vr200` | `performance` | `nvidia-vr200-performance` |
| `vr200` | `inference` | `nvidia-vr200-inference` |
| `vr200` | `multiNodeTraining` | `nvidia-vr200-multiNodeTraining` |

When `accelerator=generic`, the `nvidia-generic` profile is selected directly. The `intent` and `service` fields are ignored. This profile is self-contained (no include chain) and provides universally safe GPU tuning suitable for any NVIDIA GPU.

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

**Generic tuning** (any NVIDIA GPU, no accelerator-specific or intent-specific config):

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-tuned-generic
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/gpu.present: "true"
  packages:
    nvidia-tuned:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-tuned
      version: 0.3.0
      interrupt:
        type: reboot
      env:
        - name: INTERRUPT
          value: "true"
      configMap:
        accelerator: generic
```

**Accelerator-specific tuning** (with intent and service):

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
      version: 0.3.0
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

**AKS tuning** (H100 on Azure Kubernetes Service, Ubuntu 24.04):

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-tuned-aks
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/gpu.present: "true"
  packages:
    nvidia-tuned:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-tuned
      version: 0.3.0
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
        service: aks
```

**OCI tuning** (GB300 on OCI: NCCL topology file, PCIe ACS correction, RDMA VF boot gate):

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-tuned-oci
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/gpu.present: "true"
  packages:
    nvidia-tuned:
      image: ghcr.io/nvidia/nodewright-packages/nvidia-tuned
      version: 0.6.0
      interrupt:
        type: reboot
      env:
        - name: TOPO_PATH
          value: /etc/nccl/gb300-topo.xml
      configMap:
        intent: performance
        accelerator: gb300
        service: oci
```

`interrupt: {type: reboot}` is required as of 0.6.0, and stays required even with
`CONFIGURE_PCIE_ACS=false`, because the RDMA VF gate is a boot-ordering unit. The tuned
profile chain itself still carries no `[bootloader]` settings and applies live, but two
host-level steps do need a reboot:

- **PCIe ACS correction.** GB300 nodes ship with ACS enabled on the RoCE NIC root
  ports, which blocks peer-to-peer DMA. The `configure-pcie-acs` step runs the node's
  `rdma_topo` tool to generate a `pci=config_acs=...` bootloader drop-in, which only
  takes effect on the next boot. Correcting it raised measured all_reduce peak busbw
  from 360 GB/s to 426 GB/s on a two-node, eight-GPU RoCE run and made DMA-BUF work, which
  removes the need for `nvidia_peermem` and `NCCL_DMABUF_ENABLE=0` on nodes where the
  correction takes effect. It only takes effect on kernels that honour
  `pci=config_acs=`; on a node whose kernel does not, set `CONFIGURE_PCIE_ACS=false`
  (see the environment variables below), keep `nvidia_peermem` loaded, and keep
  `NCCL_DMABUF_ENABLE=0` set.
- **RDMA VF boot gate.** The `install-rdma-vfs-ready` step installs a
  `rdma-vfs-ready.service` unit that orders before `kubelet.service` and waits for the
  Oracle Cloud Agent to create the RDMA VFs. It is a boot-ordering gate, so it only has
  an effect from the next boot.

Both steps are no-ops for every other `service`/`accelerator` pair, so existing `eks`,
`aks`, and `bcm` deployments are unaffected and still need no `interrupt`.

### ConfigMap Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `accelerator` | Yes | — | GPU/accelerator type (e.g., `h100`, `gb200`, `generic`). When set to `generic`, intent and service are ignored |
| `intent` | No | `performance` | Workload intent (e.g., `inference`, `performance`, `multiNodeTraining`). Ignored when `accelerator=generic` |
| `service` | No | — | Service name (e.g., `eks`). If specified, service profile wraps the workload profile. Ignored when `accelerator=generic` |

> **gb300 / oci:** `gb300` ships a `performance` profile only. The base
> `nvidia-gb300-performance` profile keeps the reboot-requiring `[bootloader]` tuning
> (same as gb200); with `service=oci`, gb300 uses a bootloader-free profile chain
> (`nvidia-gb300-noreboot-base`) so the tuning itself applies without a reboot. The
> `oci` service also sets the RDMA IPv6 defaults that OCI's IPv6/SLAAC RoCE fabric
> needs, and installs the bundled NCCL topology file (see `TOPO_PATH` below).
> As of 0.6.0 the pair also runs the PCIe ACS correction and installs the RDMA VF boot
> gate, both of which require `interrupt: {type: reboot}` on the custom resource.

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
| `generic` | Baseline tuning for any NVIDIA GPU (self-contained, no intent/service required) |
| `h100` | NVIDIA H100 GPU |
| `gb200` | NVIDIA GB200 GPU |
| `gb300` | NVIDIA GB300 GPU (`performance` intent only) |

### Services (specify in `service`)

| Service | Description |
|---------|-------------|
| `eks` | eks-specific settings (MAC address policy for CNI) |
| `aks` | aks-specific settings (MAC address policy, grub.d bootloader workaround for Ubuntu) |
| `bcm` | bcm-specific settings (bootloader-free vr200 chain, applies without a reboot) |
| `oci` | oci-specific settings (RDMA IPv6 defaults, NCCL topology file, PCIe ACS correction and RDMA VF boot gate on gb300; requires `interrupt: {type: reboot}`) |

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TOPO_PATH` | No | `/etc/nccl/topo.xml` | Absolute host path the bundled NCCL topology file is written to. Only used when the configured `service`/`accelerator` pair ships one (today `oci` + `gb300`); otherwise the step is a no-op. Point `NCCL_TOPO_FILE` at the same path in your workloads. |
| `CONFIGURE_PCIE_ACS` | No | `true` | Set to `false` to skip the PCIe ACS correction and its checks. Only relevant to a `service`/`accelerator` pair that opts in (today `oci` + `gb300`). Use this on nodes whose kernel does not honour `pci=config_acs=`, where the correction cannot take effect and the post-interrupt check would otherwise fail the node. |

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

On `service: oci` with `accelerator: gb300`, also verify the two host-level steps after
the node has rebooted:

```bash
# PCIe ACS values are correct on the RoCE NIC root ports
rdma_topo check

# The kernel booted with the generated ACS argument
grep -o 'pci=config_acs=[^ ]*' /proc/cmdline

# The RDMA VF gate ran ahead of kubelet
systemctl status rdma-vfs-ready.service
journalctl -u rdma-vfs-ready.service

# The VFs the gate waited for are present
ls -d /sys/class/net/*/device/physfn | wc -l
```

## Inheritance

This package inherits all functionality from the base `tuned` package:

- Multi-distribution support (Ubuntu/Debian, CentOS/RHEL/Amazon Linux)
- Custom profile deployment via configmaps
- Script deployment for complex tuning logic
- Full lifecycle management (install, configure, uninstall)

See the [tuned package README](../tuned/README.md) for complete documentation on all features.

## Version

- **Package Version**: 0.6.0
- **Base Package**: tuned (latest via preprocess.sh)
- **Schema Version**: v1

## Additional documentation
- [NVIDA Grace Performance Tuning Guide](https://docs.nvidia.com/dccpu/grace-perf-tuning-guide/os-settings.html#operating-system-settings)