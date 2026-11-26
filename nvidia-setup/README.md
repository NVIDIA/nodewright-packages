# NVIDIA Setup Package

A NodeWright package that applies node setup steps for selected (service, accelerator) combinations. It runs **after** the machine is up (NodeWright on a live node). On EKS it manages the **kernel** (optional install or version check), the **EFA driver**, the OFI library paths, **chrony** and **local disks**; Lustre setup is present in the codebase but commented out in `apply.sh`. The AKS, OCI and BCM combinations run smaller sets of steps, described below.

## Overview

- **Opinionated:** Each (service, accelerator) has very specific baked-in configuration (kernel track, lustre, EFA versions) in `defaults/*.conf`.
- **One kernel catalog:** `skyhook_dir/kernels.conf` is the only place the package names a kernel version. Each combination says, per Ubuntu release, whether it runs the `lts` or the `hwe` kernel; the catalog maps that to an exact kernel ABI. A CR can pick another track when the catalog has one for the node's release; this version's catalog has only `aws hwe noble` (see [Kernel tracks](#kernel-tracks)).
- **Override via environment variables:** You can override the kernel track and EFA with `NVIDIA_KERNEL_TRACK`, `NVIDIA_EFA` and `NVIDIA_EFA_DRIVER`. `NVIDIA_LUSTRE` is also read, but has no effect while the Lustre step is commented out.
- **Configmap:** Only `service` and `accelerator` are required. Unsupported combinations fail with a clear error.

## Assumptions:

- OS: `ubuntu` 24.04

## Supported Combinations

See [VERSION_OVERVIEW.md](VERSION_OVERVIEW.md) for more information about what is set in each version of the package.

| service | accelerator | kernel track (noble) | default kernel      | default efa |
|---------|-------------|----------------------|---------------------|-------------|
| eks     | h100        | aws hwe              | 7.0.0-1014-aws      | 1.51.0      |
| eks     | gb200       | aws hwe              | 7.0.0-1014-aws-64k  | 1.51.0      |
| eks     | gb300       | aws hwe              | 7.0.0-1014-aws-64k  | 1.51.0      |
| aks     | h100        | none                 | (AKS-managed)       | n/a         |
| aks     | any         | none                 | (AKS-managed)       | n/a         |
| oci     | any         | none                 | (image kernel)      | n/a         |
| bcm     | h100        | none                 | n/a                 | n/a         |
| bcm     | gb200       | none                 | n/a                 | n/a         |
| bcm     | vr200       | none                 | n/a                 | n/a         |

Defaults are defined in `skyhook_dir/defaults/eks-h100.conf`, `eks-gb200.conf`, `eks-gb300.conf`, and `aks-h100.conf`; the kernel each track installs on each Ubuntu release is in `skyhook_dir/kernels.conf`. The `bcm-*`, `aks-any` and `oci-any` defaults files are intentionally empty: `bcm` only runs the kernel-headers alias, and `aks-any` and `oci-any` only run the container toolkit hardening, so none of them bake in kernel/EFA/lustre versions. `any` is the accelerator value for a service-wide combination; it does not change which nodes the package runs on (that is the NodeWright CR's node selector). Keep this table in sync when adding or changing defaults.

## Configuration

**ConfigMap (required):**

- `service` – e.g. `eks`
- `accelerator` – e.g. `h100`, `gb200`

**ConfigMap (optional):**

- `kernel_track` – `lts` or `hwe`, to run that track instead of the combination's default for the node's Ubuntu release (see [Kernel tracks](#kernel-tracks)). The catalog must have that track for the node's release, or apply fails; this version ships only `aws hwe noble`, so `lts` is not available yet. `NVIDIA_KERNEL_TRACK` wins over it. Changing it on a node that already completed this version does not reinstall the kernel: a configmap change runs only the config stage, and nvidia-setup declares none. It takes effect the next time apply runs, on a new node or with a package version bump (which runs upgrade).

**Environment variables (optional overrides):**

Set these on the package spec in the NodeWright Custom Resource (`spec.packages.<name>.env`):

- `NVIDIA_SETUP_INSTALL_KERNEL` – `true` or `false` (default: `false`). If `true`, apply **only** installs the exact kernel of the selected track (via `steps/install_kernel.sh`) and then exits; a reboot is required. If the node already has an older efa DKMS module registered, that step first upgrades EFA to `EFA_DRIVER`, so the new kernel's DKMS build of efa does not fail. When the node is already running that exact kernel (flavor included, so `-64k` on arm64) and its image, headers, modules and (where the archive ships one) modules-extra packages are installed, apt is skipped; the 7.0 aws kernels have no separate modules-extra package, so none is requested for them; the GRUB default is still set to the target kernel. After reboot, the **post-interrupt-check** verifies the running kernel matches the expected version. If `false`, apply verifies the current kernel meets the requirement (see `NVIDIA_SETUP_KERNEL_ALLOW_NEWER`) and errors otherwise, then continues with the full apply.
- `NVIDIA_SETUP_KERNEL_ALLOW_NEWER` – `true` or `false` (default: `false`). When `NVIDIA_SETUP_INSTALL_KERNEL=false`, this controls the kernel check: if `false`, the running kernel must match the required upstream version exactly; if `true`, the running kernel may be newer (current >= required).
- `NVIDIA_PIN_KERNEL` - `true` or `false` (defaults: `false`). If `true`, pin the kernel to the exact version in the package so that it will not upgrade in future.
- `APT_LOCK_WAIT_SECONDS` – whole seconds from `0` to `999999` (default: `600`). How long, in total, each apt or dpkg call waits for a lock another process holds (another NodeWright package, `apt-daily`, `unattended-upgrades`) before failing. apt waits for the dpkg lock itself through `DPkg::Lock::Timeout`; a run that fails on a held lock is retried until the time is spent.
- `NVIDIA_SETUP_APT_UPGRADE` – `true` or `false` (default: `false`). Controls the blanket `apt-get upgrade` in the **upgrade** step. Off by default because that upgrade installs whatever the distro has queued, which can include the container runtime: upgrading containerd restarts it and kills the pod running the step, taking the node NotReady mid-apply and interrupting dpkg partway through a transaction. The targeted `apt-get install` of `curl git wget gpg` in the same step is unaffected and always runs. Set to `true` on nodes where you do want the full distro upgrade.
- `NVIDIA_KERNEL_TRACK` – `lts` or `hwe` (overrides the combination's default and the `kernel_track` configmap key). Any other value fails the step, as does a track the catalog has no kernel for on the node's release.
- `NVIDIA_KERNEL` – **deprecated**, removed in 0.12.0. An exact kernel version that overrides any track; logs a warning. Use `NVIDIA_KERNEL_TRACK` instead, and ask for a catalog line when the kernel you need is missing.
- `NVIDIA_EFA` – EFA installer version
- `NVIDIA_EFA_DRIVER` – the efa driver version that installer ships, as `dkms status efa` reports it (default: `EFA_DRIVER` from the defaults file). EFA counts as current when every efa module dkms has is at least this version. Required whenever `NVIDIA_EFA` is set, since the defaults file's `EFA_DRIVER` describes its own installer; `NVIDIA_EFA` alone fails the step. A node already at this driver or newer skips the installer.

## Kernel tracks

Each combination with a kernel names its flavor and, per Ubuntu release, a **track**:

```text
# defaults/eks-h100.conf
KERNEL_FLAVOR=aws
KERNEL_TRACK_noble=hwe
```

- `lts` is the release's GA kernel, supported for the life of the release. On 26.04 (resolute) that is 7.0, and it does not change series.
- `hwe` is the release's newest hardware-enablement kernel. It moves to a new series at point releases (on 26.04, from 7.0 to 7.3 with 26.04.2), and each series is supported only until the next one replaces it, except the release's last HWE series, which is supported for the rest of the release's life (on noble that is 7.0). Newer hardware that needs a newer kernel follows `hwe`.
- Which track a SKU runs can differ by release. An H100 runs noble's `hwe` kernel (7.0, the last noble HWE) and would run resolute's `lts` kernel (also 7.0).

`skyhook_dir/kernels.conf` maps each `<flavor> <track> <release>` to an exact kernel:

```text
# renovate: datasource=deb depName=linux-image-aws-7.0 registryUrl=...suite=noble-updates...
aws hwe noble 7.0.0-1014-aws
```

- The release is matched against `VERSION_CODENAME` in the node's `/etc/os-release`. When a track is being selected, a node on a release the catalog or its combination has no track for fails apply rather than guess. The deprecated `NVIDIA_KERNEL` skips track selection entirely, so it also skips this release check.
- Each line follows Ubuntu's series-scoped meta package (`linux-image-aws-7.0`), so an automated bump only moves the ABI within the series (`7.0.0-1014` to `7.0.0-1015`), never to a new series the way the rolling `linux-aws` meta does.
- [Renovate](../.github/workflows/renovate.yaml) checks those metas every weekday and opens one pull request, `feat(nvidia-setup): update kernel catalog`, when Ubuntu publishes a new ABI. Renovate reads only the amd64 index, so the `kernel-catalog` job in `pr_build.yaml` fails that PR until the arm64 `-64k` packages are published too (run it locally with `make kernel-catalog-check`). The PR still needs hardware validation before it merges.
- The ABI is the amd64 name. On arm64 (Grace) the package installs the `-64k` flavor of the same ABI, so one line serves H100 and GB200/GB300.
- The track is chosen from, last one wins: the combination's `KERNEL_TRACK_<release>=`, the `kernel_track` configmap key, then `NVIDIA_KERNEL_TRACK`.
- Combinations without `KERNEL_FLAVOR` (`aks-*`, `oci-any`, `bcm-*`) have no track, and setting one on them fails apply when `NVIDIA_KERNEL` is unset or empty; a set `NVIDIA_KERNEL` takes precedence and the track is ignored. `bcm-*` never touches the kernel. `aks-*` and `oci-any` leave it alone unless the deprecated `NVIDIA_KERNEL` is set: apply then checks the running kernel against it, or installs it with `NVIDIA_SETUP_INSTALL_KERNEL=true`.
- Moving a track to a new series or adding a line is a pull request validated on hardware: a new series can break the EFA DKMS build (see the 0.9.0 release notes).

## BCM Service

For `service=bcm`, this package does a single thing in the apply stage: it aliases the upstream-style kernel source-tree path to Ubuntu's headers tree so that consumers (gpu-operator `nvidia-driver-daemonset`, NVIDIA DRA driver) which read `/usr/src/linux-$(uname -r)/.config` find it.

On Ubuntu the file only exists at `/usr/src/linux-headers-$(uname -r)/.config`. Without this alias, `aicr validate` stalls (DRA pod `Init:0/1`, driver daemonset unhealthy). See [AICR #1093](https://github.com/NVIDIA/aicr/issues/1093).

What this step does (full-directory symlink, idempotent across reboots and kernel upgrades):

```
ln -s linux-headers-$(uname -r) /usr/src/linux-$(uname -r)
```

For `service=bcm` the apply stage skips the kernel/EFA pipeline and runs only this step; `apply-check` verifies the symlink resolves. Because the script keys off `uname -r` at runtime, the alias is recreated by re-applying the package after a kernel upgrade.

Example SCR fragment:

```yaml
packages:
  nvidia-setup-bcm:
    image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
    version: 0.3.0
    configMap:
      service: bcm
      accelerator: h100
```

## Apply Steps (EKS)

For `service=eks` the apply step currently runs, in order:

1. **ensure_kernel** – if `NVIDIA_SETUP_INSTALL_KERNEL=false`: verify running kernel meets requirement (exact match by default; allow newer if `NVIDIA_SETUP_KERNEL_ALLOW_NEWER=true`); if `true`: install exact kernel only (then exit; reboot required), skipping apt when that exact kernel is already running with its packages installed. Before installing a kernel, if dkms has an efa module older than the configured `EFA_DRIVER`, it runs **install-efa-driver** first: installing a kernel makes dkms rebuild every efa module for it, and an efa driver too old for that kernel fails the build and leaves the kernel packages half-configured. A node with no efa module skips this, and the full setup installs EFA after the reboot.
2. **upgrade** – `apt-get update && apt-get upgrade -y`
3. **install-efa-driver** – download and run the configured AWS EFA installer. Skipped only when EFA is installed (dpkg has the `efa` package configured and dkms reports the module installed) **and** every efa module `dkms status efa` lists is at least `EFA_DRIVER`, the efa driver version that installer ships. An older efa module is upgraded in place. Before running the installer it repairs any unfinished dpkg configuration, such as an efa left half-configured by an interrupted build, which would otherwise fail every installer run with `DKMS tree already contains`.
4. **install_ofi** – add the aws-ofi-nccl plugin that the EFA installer ships (`/opt/amazon/ofi-nccl`) to `PATH` and the dynamic linker path.
5. **configure-chrony** – install chrony and point it at the Amazon Time Sync Service (`169.254.169.123`) instead of the default pools.
6. **setup_local_disks** – install `setup-local-disks` and run it in `raid0` mode: a RAID-0 of the EC2 instance store NVMe disks, with the kubelet and containerd directories bind-mounted onto it.

**install-lustre** exists in the codebase but is **commented out** in `apply.sh` for now; re-enable it there (and its check in `apply_check.sh`) when needed.

Container toolkit hardening and system-node-settings are **not** included on EKS.

## Apply Steps (AKS)

For `service=aks, accelerator=h100` the apply step currently runs:

1. **configure_ib_rdma** – writes IB module-load config (`/etc/modules-load.d/ib-umad.conf`), memlock limits (`/etc/security/limits.d/99-ib-memlock.conf`), and containerd/kubelet systemd drop-ins setting `LimitMEMLOCK=infinity`. Loads the `ib_umad` kernel module (and best-effort `rdma_ucm`, `ib_ucm`). Does **not** run `systemctl daemon-reload` or restart any services; see the AKS usage example below for how Skyhook handles that via a service interrupt.
2. **configure_container_toolkit** – see [Container toolkit hardening](#container-toolkit-hardening).

For `service=aks, accelerator=any` the apply step runs only **configure_container_toolkit**.

Kernel install/upgrade, EFA, Lustre, chrony, and local disks do not apply to AKS today (AKS ships its own Ubuntu kernel; IB/RDMA is handled by the step above).

## Apply Steps (OCI)

For `service=oci, accelerator=any` the apply step runs only **configure_container_toolkit**. The node image's kernel, driver and DOCA stack are left as they are.

## Container toolkit hardening

On nodes where the node's own NVIDIA container toolkit handles every container (AKS: containerd's default runtime is `nvidia-container-runtime`; OKE: the node bootstrap installs an always-on CRI-O OCI hook), the toolkit's default `accept-nvidia-visible-devices-envvar-when-unprivileged = true` gives any unprivileged pod that sets `NVIDIA_VISIBLE_DEVICES` every GPU on the node, without a Kubernetes allocation.

**configure_container_toolkit** runs `nvidia-ctk config --in-place` on `/etc/nvidia-container-runtime/config.toml` to set:

- `accept-nvidia-visible-devices-envvar-when-unprivileged = false`, which stops unprivileged containers from selecting GPUs through the environment variable;
- `accept-nvidia-visible-devices-as-volume-mounts = true`, so device plugins that hand out GPUs as volume mounts keep working (OKE's `NvidiaGpuPlugin` add-on runs with `deviceListStrategy=volume-mounts`).

The toolkit re-reads its config on every container start, so the step needs no interrupt. When the node has no `/etc/nvidia-container-runtime/config.toml` (a GPU Operator toolkit owns the runtime, as on driverless pools), there is nothing to harden and the step does nothing. When the file exists but `nvidia-ctk` does not, the host toolkit is incomplete (a GPU Operator toolkit keeps its own config under its install directory), so the step logs a warning and skips rather than blocking the node.

Things to know before enabling it:

- **Device plugin strategy.** GPUs a device plugin allocates must reach containers through CDI or volume mounts. A device plugin on the default `envvar` strategy hands allocations over through `NVIDIA_VISIBLE_DEVICES`, which unprivileged containers can no longer use, so their allocated GPUs would disappear.
- **Timing.** Pods that start before the step runs are not covered. Use `runtimeRequired: true` on the NodeWright CR so workloads wait until the package has run.
- **Upgrades.** The package's `upgrade` stage runs `apply.sh`, so nodes moving to this version from an earlier one get the keys without a re-apply. The step itself needs no interrupt, but NodeWright runs whatever interrupt the CR declares after any version change: on `aks-h100` that restarts containerd and kubelet, as every previous version bump did.
- **One-time write.** The package sets the keys when it applies or upgrades and does not re-assert them. If something later rewrites `config.toml` on the same node, the keys stay changed until the package runs again. Downgrading or removing the package leaves the keys set: it has no uninstall stage.
- **Running next to a DaemonSet that sets the same keys** (aicr's `nvidia-toolkit-hardening`): both write the same values with `nvidia-ctk`, so running both during a migration changes nothing; remove the DaemonSet once nodes run this version.
- **No `nvidia-ctk`.** A node whose `config.toml` has no `nvidia-ctk` next to it is not hardened; look for the step's `WARNING` line if such a node runs workloads through the host toolkit.

## Apply-Check

When `NVIDIA_SETUP_INSTALL_KERNEL=true` is set, apply-check (and **post-interrupt-check**) only verify that the running kernel matches the expected version from the selected kernel track (or the deprecated `NVIDIA_KERNEL`). When the env var is false or unset, apply-check on EKS checks upgrade (apt update ok), EFA present at `EFA_DRIVER` or newer, the OFI paths, chrony and local disks; the Lustre check is commented out in `apply_check.sh` to match `apply.sh`. Re-enable it in both when adding the step back.

## Post-Interrupt-Check

When `NVIDIA_SETUP_INSTALL_KERNEL=true` is set, the kernel install step may trigger a reboot. After the interrupt (reboot), **post-interrupt-check** runs (with the same env var) and verifies the running kernel matches the expected version from the selected kernel track (or the deprecated `NVIDIA_KERNEL`); it fails if not.

## Kernel install with interrupt reboot + full setup (two packages)

When you need to install the exact default kernel and then run the rest of the setup (EFA, OFI, chrony and local disks), use two nvidia-setup packages:

1. **First package** – kernel only, with **interrupt: reboot**. Apply runs only the kernel install (and may reboot); after reboot, post-interrupt-check verifies the kernel.
2. **Second package** – full setup, with **dependsOn** the first. Apply runs the normal steps (upgrade, EFA, OFI, chrony and local disks) and sees the correct running kernel (no kernel install, just the kernel check from **ensure_kernel**).

Both packages use the same `service` and `accelerator` configMap; only the first sets `NVIDIA_SETUP_INSTALL_KERNEL=true`. Each package resolves the kernel on its own, so a track override must be identical on both: the same `kernel_track` key and `NVIDIA_KERNEL_TRACK` (and, while it exists, `NVIDIA_KERNEL`). Otherwise the second package checks for a different kernel than the first installed. The first package must declare an interrupt (e.g. reboot) so the node reboots into the new kernel before the second package runs.

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
      image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
      version: 0.11.0
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
      image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
      version: 0.11.0
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
        nvidia-setup-kernel: 0.11.0
```

Flow: apply `nvidia-setup-kernel` → kernel install → reboot (interrupt) → post-interrupt-check verifies kernel → apply `nvidia-setup-full` (kernel check passes, then upgrade, EFA, OFI, chrony and local disks).

## Upgrading to a new version

Raising a package's `version` on a node that completed an earlier version does not run `apply`; the operator runs the `upgrade` stage, then `config` and the interrupt. `upgrade` runs `apply.sh` and `upgrade-check` runs `apply_check.sh`, so a version bump does everything a first apply does, with the same `NVIDIA_SETUP_INSTALL_KERNEL` routing. Before 0.9.0 the package declared no upgrade mode, so a version bump ran nothing and still reported complete.

In the two-package layout above, bump both packages and the `dependsOn` that names the kernel package's version. The kernel package's reboot then runs again, so the full package's apply sees the new kernel. If the reboot comes from another package whose version does not change, that package does not run again, and the full package's apply runs on the old kernel and fails its kernel check.

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
      image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
      version: 0.11.0
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
          value: "1.51.0"
        - name: NVIDIA_EFA_DRIVER
          value: "3.3.1"
```

## AKS Usage Example

On AKS, containerd and kubelet need `LimitMEMLOCK=infinity` for IB/RDMA workloads. The package writes the drop-in files; Skyhook restarts the services via a `service` interrupt.

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: nvidia-setup-aks
spec:
  nodeSelectors:
    matchLabels:
      # Only run on IB-capable nodes (label set by NFD's network rule on AKS ND-series).
      feature.node.kubernetes.io/pci-15b3.present: "true"
  packages:
    nvidia-setup:
      image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
      version: 0.5.0
      resources:
        cpuLimit: 1000m
        cpuRequest: 500m
        memoryLimit: 1024Mi
        memoryRequest: 512Mi
      configMap:
        service: aks
        accelerator: h100
      # Skyhook runs `systemctl daemon-reload` then restarts containerd and kubelet
      # after the apply step completes. The package script does not perform the
      # restart itself.
      interrupt:
        type: service
        services:
          - containerd
          - kubelet
```

This replaces the equivalent privileged DaemonSet (`ib-node-config-aks.yaml`) that aicr currently ships under `recipes/components/network-operator/manifests/`. With `version: 0.10.0` or later, it also sets the container toolkit device-isolation keys that aicr's `nvidia-toolkit-hardening` DaemonSet sets today ([NVIDIA/aicr#1839](https://github.com/NVIDIA/aicr/issues/1839)).

For OCI (OKE), the toolkit hardening needs no interrupt. Set `runtimeRequired: true` so workloads wait for it:

```yaml
spec:
  runtimeRequired: true
  packages:
    nvidia-setup:
      image: ghcr.io/nvidia/nodewright-packages/nvidia-setup
      version: 0.10.0
      configMap:
        service: oci
        accelerator: any
```

## Adding a New (service, accelerator)

1. Add `skyhook_dir/defaults/<service>-<accelerator>.conf` with `KERNEL_FLAVOR=` and `KERNEL_TRACK_<release>=` (`lts` or `hwe` for each Ubuntu release the combination supports; add the matching line to `skyhook_dir/kernels.conf` if it is missing), `LUSTRE=`, `EFA=`, and `EFA_DRIVER=` (the efa driver version the `EFA` installer ships, as `dkms status efa` reports it). Do not set `KERNEL=` in a defaults file: the loader rejects it.
2. In `apply.sh`, add a `run_<service>_<accelerator>()` function that runs the step scripts for that combination, and add a case branch: `<service>-<accelerator>) run_<service>_<accelerator> ;;`.
3. In `apply_check.sh`, add `check_<service>_<accelerator>()` and the same case branch.
4. In `post_interrupt_check.sh`, add the combination to a case branch (it rejects unknown combinations).
5. Rebuild the image and update this README’s supported combinations table.
