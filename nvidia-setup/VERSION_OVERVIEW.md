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

0.5.1 bumps the eks-gb200 EFA installer to `1.49.0` (H100/x86_64 stays on `1.48.0`): 1.48.0's `efa` DKMS module fails to build against the 6.17 arm64 kernel in the apply flow (its kernel autoconf misdetects the kernel and falls back to a pre-4.20 RDMA API that does not compile), while 1.49.0 builds cleanly. 0.5.1 also removes every installed kernel except the running one before the EFA install (`prune_foreign_kernels`), so EFA's `efa` DKMS module is only ever built against the booted/target kernel. A stray non-running kernel (for example the base-AMI 4k `*-aws` kernel on a Grace node running the `-64k` kernel) previously made the EFA `.deb` post-install fail its DKMS build and abort the whole apply. On a 64k node the prune also purges the 4k sibling flavour's meta packages (`linux-image-aws` etc.) in the same transaction, so apt cannot upgrade the meta and re-pull a fresh 4k kernel.

| service | accelerator | kernel              | efa         | chrony | raid0 | OFI | bcm headers alias | ib rdma memlock |
|---------|-------------|---------------------|-------------|--------|-------|-----|-------------------|-----------------|
| eks     | h100        | 6.17.0-1019-aws     | 1.48.0      |  Y     |  Y    |  Y  |  N                |  N              |
| eks     | gb200       | 6.17.0-1019-aws-64k | 1.49.0      |  Y     |  Y    |  Y  |  N                |  N              |
| aks     | h100        | (AKS-managed)       | n/a         |  N     |  N    |  N  |  N                |  Y              |
| bcm     | h100        | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
| bcm     | gb200       | n/a                 | n/a         |  N     |  N    |  N  |  Y                |  N              |
