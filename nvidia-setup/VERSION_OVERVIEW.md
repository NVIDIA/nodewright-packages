# 0.1.x

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI |
|---------|-------------|---------------------|-------------|--------|-------|-----|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  N  |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  N  |

# 0.2.x

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI |
|---------|-------------|---------------------|-------------|--------|-------|-----|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |

# 0.3.x

Adds the `bcm` service. `service=bcm`'s sole job is to alias `/usr/src/linux-$(uname -r)` to the Ubuntu `linux-headers-$(uname -r)` tree so consumers reading `/usr/src/linux-$(uname -r)/.config` find it (AICR #1093). For `service=bcm` the apply stage skips the kernel/EFA pipeline and runs only this single step.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|
| eks     | h100        | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  N                |
| eks     | gb200       | 6.14.0-1018-aws     | 1.47.0      |  Y     |  Y    |  Y  |  N                |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |

# 0.4.x

Bumps EKS defaults to kernel `6.17.0-1019-aws` and EFA `1.48.0`. `resolve_full_kernel` now appends the `-64k` page-size variant on arm64, so GB200 (Grace) installs `6.17.0-1019-aws-64k` while H100 (x86_64) stays on `6.17.0-1019-aws`.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|
| eks     | h100        | 6.17.0-1019-aws     | 1.48.0      |  Y     |  Y    |  Y  |  N                |
| eks     | gb200       | 6.17.0-1019-aws-64k | 1.48.0      |  Y     |  Y    |  Y  |  N                |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |

# 0.5.x

Adds the `aks` service with the `aks-h100` combination. For `service=aks` the apply stage runs a single `configure_ib_rdma` step that loads the InfiniBand kernel modules (`ib_umad`, best-effort `rdma_ucm`/`ib_ucm`), persists them via `/etc/modules-load.d/ib-umad.conf`, writes memlock limits to `/etc/security/limits.d/99-ib-memlock.conf`, and sets `LimitMEMLOCK=infinity` on containerd and kubelet through systemd drop-ins. Service restarts are handled by the Skyhook interrupt declared in the CR, not by the package. The kernel/EFA pipeline does not run on AKS (AKS manages its own Ubuntu kernel), and `ensure_kernel` no-ops when `KERNEL` is unset.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias | ib rdma memlock |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|-----------------|
| eks     | h100        | 6.17.0-1019-aws     | 1.48.0      |  Y     |  Y    |  Y  |  N                |  N              |
| eks     | gb200       | 6.17.0-1019-aws-64k | 1.48.0      |  Y     |  Y    |  Y  |  N                |  N              |
| aks     | h100        | (AKS-managed)       | n/a         |  N     |  N    |  N  |  N                |  Y              |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |

# 0.6.x

Adds the `vr200` accelerator on the `bcm` service only: `bcm-vr200` behaves like `bcm-gb200` (kernel-headers alias only; no kernel/EFA/lustre baked in). An `eks-vr200` flavor is intentionally not shipped yet: it needs a kernel/AMI that cannot be validated here.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias | ib rdma memlock |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|-----------------|
| eks     | h100        | 6.17.0-1019-aws     | 1.48.0      |  Y     |  Y    |  Y  |  N                |  N              |
| eks     | gb200       | 6.17.0-1019-aws-64k | 1.48.0      |  Y     |  Y    |  Y  |  N                |  N              |
| aks     | h100        | (AKS-managed)       | n/a         |  N     |  N    |  N  |  N                |  Y              |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
| bcm     | vr200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
