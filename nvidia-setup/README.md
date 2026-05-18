# NVIDIA Setup Package

A NodeWright package that applies node setup steps for selected (service, accelerator) combinations. It runs **after** the machine is up (NodeWright on a live node). **Currently** it controls kernel (optional install or version check), package upgrade, EFA driver install, OFI configuration, chrony, host sysctl/UFW tuning (`system_node_settings`), cloud-init / EC2 IMDS drop-ins (`cloud_init_cfg`), and local disk setup. Lustre client install is supported as an opt-in step (see `SETUP_LUSTRE` below).

## Overview

- **Opinionated:** Each (service, accelerator) has very specific baked-in configuration (exact kernel, lustre, EFA versions) in `defaults/*.conf`.
- **Override via environment variables:** You can override kernel, EFA, lustre (and ofi if added) with `NVIDIA_KERNEL`, `NVIDIA_EFA`
- **Configmap:** Only `service` and `accelerator` are required. Unsupported combinations fail with a clear error.

## Assumptions:

- OS: `ubuntu` 24.04

## Supported Combinations

See [VERSION_OVERVIEW.md](VERSION_OVERVIEW.md) for more information about what is set in each version of the package.

| service | accelerator | default kernel      |  default efa |
|---------|-------------|---------------------|--------------|
| eks     | h100        | 6.14.0-1018-aws     |  1.47.0      |
| eks     | gb200       | 6.14.0-1018-aws     |  1.47.0      |

Defaults are defined in `skyhook_dir/defaults/eks-h100.conf` and `eks-gb200.conf`. Keep this table in sync when adding or changing defaults.

## Configuration

**ConfigMap (required):**

- `service` – e.g. `eks`
- `accelerator` – e.g. `h100`, `gb200`

**Environment variables (optional overrides):**

Set these on the package spec in the NodeWright Custom Resource (`spec.packages.<name>.env`):

- `NVIDIA_SETUP_INSTALL_KERNEL` – `true` or `false` (default: `false`). If `true`, apply **only** installs the exact kernel from the defaults file (via `downgrade_kernel.sh`) and then exits; a reboot is required. After reboot, the **post-interrupt-check** verifies the running kernel matches the expected version. If `false`, apply verifies the current kernel meets the requirement (see `NVIDIA_SETUP_KERNEL_ALLOW_NEWER`) and errors otherwise, then continues with the full apply.
- `NVIDIA_SETUP_KERNEL_ALLOW_NEWER` – `true` or `false` (default: `false`). When `NVIDIA_SETUP_INSTALL_KERNEL=false`, this controls the kernel check: if `false`, the running kernel must match the required upstream version exactly; if `true`, the running kernel may be newer (current >= required).
- `NVIDIA_PIN_KERNEL` - `true` or `false` (defaults: `false`). If `true`, pin the kernel to the exact version in the package so that it will not upgrade in future.
- `NVIDIA_KERNEL` – kernel version (overrides default from defaults file)
- `NVIDIA_EFA` – EFA installer version
- `NVIDIA_LUSTRE` – Lustre source: either `aws` (use the AWS FSx Lustre apt repo) or a git ref to build from source. Only meaningful when `SETUP_LUSTRE=true`.
- `SETUP_LUSTRE` – `true` or `false` (default: `false`). Opt-in: when `true`, the apply step installs the Lustre client modules for the running kernel on `eks-h100` / `eks-gb200`. Default off; the Lustre install is heavy (apt repo + kernel-version-matched package), so leave off unless the deployment uses FSx for Lustre.

## Apply Steps (EKS)

For `service=eks` the apply step currently runs, in order:

1. **ensure_kernel** – if `NVIDIA_SETUP_INSTALL_KERNEL=false`: verify running kernel meets requirement (exact match by default; allow newer if `NVIDIA_SETUP_KERNEL_ALLOW_NEWER=true`); if `true`: install exact kernel only (then exit; reboot required).
2. **upgrade** – `apt-get update && apt-get upgrade -y`
3. **install-efa-driver** – download and run the AWS EFA installer for the version in `NVIDIA_EFA`.
4. **install_ofi** – install the OFI (libfabric) plugin for the EFA driver.
5. **install-lustre** *(only when `SETUP_LUSTRE=true`)* – install the Lustre client kernel modules for the running kernel using the source specified by `NVIDIA_LUSTRE`.
6. **configure-chrony** – configure the chrony NTP client for the AWS time sync service.
7. **system_node_settings** – write `/etc/sysctl.d/999-nvidia-tuning.conf` with inotify limits and mask UFW.
8. **cloud_init_cfg** – write the EC2 IMDS datasource config and the cloud-init wait-for-net-device systemd + udev drop-ins.
9. **setup_local_disks raid0** – configure local NVMe disks as a RAID-0 array.

## Apply-Check

When `NVIDIA_SETUP_INSTALL_KERNEL=true` is set, apply-check (and **post-interrupt-check**) only verify that the running kernel matches the expected version from defaults/env. When the env var is false or unset, apply-check runs the check counterparts for each step listed in [Apply Steps (EKS)](#apply-steps-eks) — in the same order, and with `install_lustre_check.sh` gated on `SETUP_LUSTRE=true` to match `apply.sh`.

## Post-Interrupt-Check

When `NVIDIA_SETUP_INSTALL_KERNEL=true` is set, the kernel install step may trigger a reboot. After the interrupt (reboot), **post-interrupt-check** runs (with the same env var) and verifies the running kernel matches the expected version from defaults/env; it fails if not.

## Kernel install with interrupt reboot + full setup (two packages)

When you need to install the exact default kernel and then run the rest of the setup (EFA, OFI, chrony, host tuning, cloud-init drop-ins, local disks, and optionally Lustre via `SETUP_LUSTRE=true`), use two nvidia-setup packages:

1. **First package** – kernel only, with **interrupt: reboot**. Apply runs only the kernel install (and may reboot); after reboot, post-interrupt-check verifies the kernel.
2. **Second package** – full setup, with **dependsOn** the first. Apply runs the normal steps (upgrade, EFA, OFI, chrony, `system_node_settings`, `cloud_init_cfg`, `setup_local_disks`, plus Lustre when `SETUP_LUSTRE=true`) and will see the correct running kernel (no kernel install, just the “current kernel >= required” check).

Both packages use the same `service` and `accelerator` configMap; only the first sets `NVIDIA_SETUP_INSTALL_KERNEL=true`. The first package must declare an interrupt (e.g. reboot) so the node reboots into the new kernel before the second package runs.

Example (adjust `dependsOn` / interrupt keys to match your NodeWright API):

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-setup-eks
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/gpu: "true"
  packages:
    # 1) Install exact kernel only; reboot required
    nvidia-setup-kernel:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-setup
      version: 0.1.0
      configMap:
        service: eks
        accelerator: h100
      env:
        - name: NVIDIA_SETUP_INSTALL_KERNEL
          value: "true"
      # Declare reboot interrupt so the node reboots after kernel install
      interrupt:
        type: reboot

    # 2) Full setup after kernel is in place
    nvidia-setup-full:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-setup
      version: 0.1.0
      resources:
        cpuLimit: 4000m
        cpuRequest: 2000m
        memoryLimit: 8192Mi
        memoryRequest: 4096Mi
      configMap:
        service: eks
        accelerator: h100
      env:
        - name: NVIDIA_SETUP_INSTALL_KERNEL
          value: "false"
      dependsOn:
        nvidia-setup-kernel: 0.1.0
```

Flow: apply `nvidia-setup-kernel` → kernel install → reboot (interrupt) → post-interrupt-check verifies kernel → apply `nvidia-setup-full` (kernel check passes, then upgrade, EFA, OFI, chrony, `system_node_settings`, `cloud_init_cfg`, `setup_local_disks`, and Lustre when `SETUP_LUSTRE=true`).

## Usage Example

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-setup-eks
spec:
  nodeSelectors:
    matchLabels:
      nvidia.com/gpu: "true"
  packages:
    nvidia-setup:
      image: ghcr.io/nvidia/skyhook-packages/nvidia-setup
      version: 0.1.0
      resources:
        cpuLimit: 4000m
        cpuRequest: 2000m
        memoryLimit: 8192Mi
        memoryRequest: 4096Mi
      configMap:
        service: eks
        accelerator: h100
      # Optional overrides:
      env:
        - name: NVIDIA_EFA
          value: "1.31.0"
```

## Adding a New (service, accelerator)

1. Add `skyhook_dir/defaults/<service>-<accelerator>.conf` with `kernel=`, `lustre=`, `efa=`.
2. In `apply.sh`, add a `run_<service>_<accelerator>()` function that runs the step scripts for that combination, and add a case branch: `<service>-<accelerator>) run_<service>_<accelerator> ;;`.
3. In `apply_check.sh`, add `check_<service>_<accelerator>()` and the same case branch.
4. Rebuild the image and update this README’s supported combinations table.
