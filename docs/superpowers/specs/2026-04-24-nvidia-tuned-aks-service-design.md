# nvidia-tuned: add `aks` service for H100 on Azure Kubernetes Service

## Goal

Add Azure Kubernetes Service (AKS) support to the `nvidia-tuned` package as a new `service` value (alongside `eks`). Target the AKS default node image (Ubuntu 24.04 with containerd) running on NVIDIA H100 VMs (primarily `Standard_ND96isr_H100_v5`). Expose all three existing intents — `performance`, `inference`, `multiNodeTraining` — under `accelerator: h100`, `service: aks`.

## Non-goals

- Azure Linux 3 (cbl-mariner) — the default AKS node image is Ubuntu 24.04; Azure Linux is out of scope for v1.
- GB200 on AKS — ND GB200 v6 is not yet stable/GA on AKS. Will follow in a later change.
- Any Hyper-V / Azure-host-specific bootloader tuning (`clocksource=tsc`, `processor.max_cstate=1`, etc.) — unverified on NVIDIA workloads; excluded until benchmarked.
- Refactoring the EEVDF-scheduler sysctl removal into `profiles/os/ubuntu/24.04/` — flagged as future cleanup; keeps this change reviewable.

## Context

### How `nvidia-tuned` selects a profile today

`nvidia-tuned/skyhook_dir/prepare_nvidia_profiles.sh` reads three configmap fields — `accelerator`, `intent`, and optional `service`. When `service` is set, the script:

1. Locates `profiles/service/$service/`.
2. Applies any service-specific profile override (`$service/nvidia-{accelerator}-{intent}.conf`) on top of the base workload profile at `/etc/tuned/nvidia-{accelerator}-{intent}/`.
3. Creates a final wrapper profile at `/etc/tuned/{service}-{accelerator}-{intent}/tuned.conf` from `$service/tuned.conf.template`, injecting an `include=` line that points at the workload profile.
4. Copies any extra files from the service dir (scripts, etc.) into that wrapper profile directory, excluding `tuned.conf.template` and any `.conf` files.

The script discovers service directories from the filesystem. Adding a new service is purely a matter of adding a directory under `profiles/service/`.

### What the `eks` service currently does

`profiles/service/eks/` contains:

- `tuned.conf.template` — minimal wrapper that references `${i:PROFILE_DIR}/script.sh` via the tuned `[script]` plugin.
- `script.sh` — tuned script-plugin lifecycle (`start` / `stop` / `verify`). On start it writes `/etc/systemd/network/99-default.link.d/mac-address-policy.conf` (containing `MACAddressPolicy=none`) and invokes `bootloader.sh`.
- `bootloader.sh` — writes `/etc/default/grub.d/99_tuned.cfg` that sources `/etc/tuned/bootcmdline` and sets `GRUB_CMDLINE_LINUX_DEFAULT`, then runs `update-grub`. This is the "bootloader workaround" that makes `[bootloader]` stanzas in tuned profiles actually take effect on Ubuntu grub.
- `nvidia-h100-inference.conf`, `nvidia-gb200-inference.conf` — service-specific overrides that drop `kernel.sched_latency_ns` / `kernel.sched_min_granularity_ns` (absent on kernel 6.8's EEVDF scheduler).

### Why AKS fits the same shape

| Aspect | AKS Ubuntu 24.04 | EKS Ubuntu 24.04 | Consequence |
|---|---|---|---|
| tuned daemon installable | yes | yes | Can use `nvidia-tuned` (not a separate `nvidia-tuning-aks`) |
| grub-based bootloader | yes (Ubuntu default) | yes | Same `bootloader.sh` grub.d workaround applies |
| Kernel version | 6.8 (Ubuntu 24.04) | 6.8 (Ubuntu 24.04) | EEVDF scheduler — same sysctl removals |
| NIC MAC changes on stop/deallocate or host migration | yes (Azure behavior) | yes (AWS ENI behavior) | Same `MACAddressPolicy=none` drop-in |
| Container runtime | containerd | containerd | No containerd drop-in needed for H100 |
| Serial console | ttyS0 115200 (Azure Serial Console) | ttyS0 115200 (AWS) | Base profile's `console=` bootloader stanza works unchanged |
| SR-IOV / IOMMU on H100 VMs | yes (ND v5 series) | yes | Base `iommu=pt` works unchanged |

The only AKS-vs-EKS differences that require a distinct service profile are **branding/logging** (summary strings that say "AKS") and **source-of-truth separation** (so that future Azure-specific tweaks have a home without touching EKS).

## Design

### File layout

```
nvidia-tuned/profiles/service/
├── common/                              # NEW
│   ├── mac-address-policy.sh            # extracted from eks/script.sh
│   └── bootloader.sh                    # moved from eks/bootloader.sh
├── eks/
│   ├── tuned.conf.template              # unchanged
│   ├── script.sh                        # UPDATED: sources common/mac-address-policy.sh and common/bootloader.sh
│   ├── nvidia-h100-inference.conf       # unchanged
│   └── nvidia-gb200-inference.conf      # unchanged
└── aks/                                 # NEW
    ├── tuned.conf.template
    ├── script.sh                        # sources common/mac-address-policy.sh and common/bootloader.sh
    └── nvidia-h100-inference.conf       # drops EEVDF sysctls (mirrors eks variant, "AKS-compatible" summary)
```

Notes:
- `eks/bootloader.sh` is deleted; the identical logic lives in `common/bootloader.sh`.
- No `aks/nvidia-h100-performance.conf` or `aks/nvidia-h100-multiNodeTraining.conf` — the base profiles work unchanged on Ubuntu 24.04 + Azure.
- No `aks/nvidia-gb200-*.conf` files in v1 (GB200 on AKS is out of scope).

### `prepare_nvidia_profiles.sh` change

`deploy_service_profile()` currently copies every file in the selected service directory into the final profile directory, skipping `tuned.conf.template` and `*.conf`. It does not care about `common/` today because no such directory exists under `profiles/service/`.

Two small changes to the prepare script:

1. **Guard** — reject `configMap.service: common` with a clear error (`common` is now a reserved name used for shared helpers). Without this, the script would fail later inside `deploy_service_profile` with a misleading "Service template not found" message.

2. **Helper copy step** — shared helpers under `profiles/service/common/` need to be reachable at runtime from each service's `script.sh`. Tuned copies the service directory content into `/etc/tuned/{service}-{accelerator}-{intent}/`, so the prepare script must also copy `profiles/service/common/*.sh` into the final profile dir. Then each service's `script.sh` sources its siblings via `"$SCRIPT_DIR/mac-address-policy.sh"` and invokes `"$SCRIPT_DIR/bootloader.sh"` — the same `SCRIPT_DIR` pattern that already exists.

Implementation sketch for the helper copy (inside `deploy_service_profile`, before the existing service-file copy loop):

```bash
# Copy shared helper scripts (if any) into the final profile dir
if [ -d "$PROFILES_DIR/service/common" ]; then
    for helper in "$PROFILES_DIR/service/common"/*.sh; do
        [ -f "$helper" ] || continue
        cp "$helper" "$TUNED_USER_DIR/$final_profile_name/$(basename "$helper")"
        chmod +x "$TUNED_USER_DIR/$final_profile_name/$(basename "$helper")"
    done
fi
```

And a guard at the top of `main()` (or in service validation):

```bash
if [ "${SERVICE:-}" = "common" ]; then
    echo "ERROR: 'common' is a reserved service name (used for shared helpers)"
    exit 1
fi
```

### `common/mac-address-policy.sh`

Extracted verbatim from `eks/script.sh`. Exposes three functions — `apply_network_dropin`, `remove_network_dropin`, `verify_network_dropin` — and does nothing on source (no side effects).

### `common/bootloader.sh`

Moved verbatim from `eks/bootloader.sh`. Writes `/etc/default/grub.d/99_tuned.cfg`, runs `update-grub`. Executable on its own (keeps the existing behavior where `script.sh` invokes it directly).

### `eks/script.sh` (updated)

```bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/mac-address-policy.sh"

run_bootloader() {
    if [ -f "$SCRIPT_DIR/bootloader.sh" ]; then
        "$SCRIPT_DIR/bootloader.sh"
    fi
}

cmd="${1:-}"
case "$cmd" in
    start)   apply_network_dropin; run_bootloader ;;
    stop)    remove_network_dropin ;;
    verify)  verify_network_dropin "$@" ;;
    *)       echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2; exit 1 ;;
esac
```

Behavior is identical to the pre-change EKS script.

### `aks/tuned.conf.template`

```
[main]
summary=NVIDIA AKS profile with MAC address policy configuration

[script]
script=${i:PROFILE_DIR}/script.sh
```

### `aks/script.sh`

Byte-identical to the new `eks/script.sh` above. Same lifecycle, same helpers, same behavior — the only reason both exist is to give each service a separate identity and a place for future divergence. (A shared sibling `script.sh` at `common/` level would save ~20 lines but would require more invasive changes to how the prepare script copies files into the final profile dir; keeping a per-service `script.sh` is the smaller change.)

### `aks/nvidia-h100-inference.conf`

```
[main]
include=nvidia-h100-performance
summary=Optimized for inference workloads (AKS-compatible)

[bootloader]
# Isolate CPUs for inference processes, 2 per socket
cmdline_isolcpus=isolcpus=${f:cpulist_invert:${f:calc_isolated_cores:2}}
# Allocate hugepages for better memory access
cmdline_hugepages=hugepagesz=2M hugepages=8192

[sysctl]
# Minimize latency
vm.swappiness=1
# Note: kernel.sched_latency_ns and kernel.sched_min_granularity_ns are not
# available on Ubuntu 24.04 kernel 6.8 (EEVDF scheduler replaced CFS).
```

### Inheritance chain

When a user applies `configMap: { intent: inference, accelerator: h100, service: aks }`:

```
aks-h100-inference (active profile)
  └── includes: nvidia-h100-inference         [AKS override: drops EEVDF sysctls]
        └── includes: nvidia-h100-performance
              └── includes: nvidia-acs-disable
                    └── includes: nvidia-base
```

For `performance` and `multiNodeTraining` intents (no AKS-specific override), the chain uses the unmodified base profile at each level.

## Documentation changes

### `nvidia-tuned/README.md`

1. In the **Services** table:
   ```
   | aks | AKS-specific settings (MAC address policy, grub.d bootloader workaround for Ubuntu) |
   ```
2. Add a usage example under the existing EKS block:
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

### `nvidia-tuned/CHANGELOG.md`

Add `0.3.0` entry summarizing: new `aks` service (H100, all three intents); extraction of `mac-address-policy.sh` and `bootloader.sh` into `profiles/service/common/`; reserved `common` service name.

## Tests

`tests/integration/nvidia_tuned/test_prepare_nvidia_profiles.py` gains three tests, mirroring the existing EKS service tests:

1. **`test_prepare_nvidia_profiles_with_aks_service`** — parameterized over `accelerator=h100` × `intent in {performance, inference, multiNodeTraining}`. Asserts that the final profile dir `/etc/tuned/aks-h100-{intent}/` exists with a `tuned.conf` whose `[main]` has `include=nvidia-h100-{intent}`, and that `script.sh`, `mac-address-policy.sh`, `bootloader.sh` are present and executable inside that dir.

2. **`test_prepare_nvidia_profiles_aks_service_specific_profile`** — runs with `intent=inference` and asserts that the service-specific override is applied (the final profile's include points at `nvidia-h100-inference` but that workload profile's `tuned.conf` on disk is the AKS override — contains the `AKS-compatible` summary and does NOT contain `kernel.sched_latency_ns`).

3. **`test_prepare_nvidia_profiles_common_service_rejected`** — sets `service: common` in the configmap and asserts the prepare script exits non-zero with a clear error message, and that no `/etc/tuned/common-*` directory is created.

The existing EKS service tests should continue passing unchanged after the script.sh refactor (byte-for-byte runtime behavior).

## Versioning

- `nvidia-tuned/config.json`: `package_version` → `0.3.0`.
- No change to the `tuned` base package version.
- No tag is created as part of this spec; release tagging follows the repo's normal workflow.

## Risks and verification

| Risk | Mitigation |
|---|---|
| The `common/` directory breaks service discovery for someone who set `service: common` already. | Unlikely in practice (no such service existed before), and explicit guard + error message catches it. |
| Refactoring `eks/script.sh` to source external helpers changes runtime behavior. | Existing EKS integration tests rerun against the refactored script; behavior is byte-equivalent. |
| The grub.d workaround might not be needed on some AKS-specific kernel/grub packaging variants. | Behavior is idempotent — writing `99_tuned.cfg` and running `update-grub` is safe even if no `[bootloader]` stanza sets cmdline entries. Matches the EKS precedent. |
| `MACAddressPolicy=none` drop-in is applied on nodes where it isn't needed. | Benign on modern Ubuntu; matches EKS precedent. |

## Rollout

1. Merge refactor + new service in one PR (single reviewable unit; no runtime behavior change for EKS users).
2. Tag `nvidia-tuned/0.3.0` per the repo's standard release process.
3. AKS consumers update their Skyhook manifests to set `service: aks` and bump to `version: 0.3.0`.
