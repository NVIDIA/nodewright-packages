# NVIDIA Tuning GKE Package

A NodeWright package that extends the base **tuning** package with baked-in H100 and GB200 tuning configs for GKE. It mirrors the sysctl (and optional containerd drop-in) from the [nvidia-tuned](../nvidia-tuned/). **GRUB/kernel cmdline is not used**—GKE nodes do not use grub, so only sysctl and service drop-ins are applied. This package is required instead of the nvidia-tuned because Container Optimized OS does not include tuned and it cannot be installed.

## Overview

- **Inherits from:** [tuning](../tuning/) (same pattern as nvidia-tuned inheriting from tuned).
- **ConfigMap:** You supply only `accelerator` and `intent`; the package fills in `sysctl.conf` and for GB200 `service_containerd.conf` from baked-in profiles, then runs the base tuning package to apply them.

## ConfigMap (required)

| Key           | Values              | Description |
|---------------|---------------------|-------------|
| `accelerator` | `h100`, `gb200`     | GPU/accelerator type. |
| `intent`      | `inference`, `multiNodeTraining` | Workload intent. |

Profiles are selected by the pair `{accelerator}/{intent}` and live under `profiles/{accelerator}/{intent}/` (e.g. `profiles/h100/inference/`, `profiles/gb200/multiNodeTraining/`). The prepare step discovers available accelerators and intents from the filesystem, so new profiles can be added without changing the scripts.

## Interrupts

Use specific service restarts in order to get the values applied. For current configurations you can use the interrupt below to get the sysctl settings loaded; DO NOT USE reboot interrupt as NodeWright has to re-apply all changes every reboot and this will cause an infinite loop. Example:

```yaml
packages:
  nvidia-tuning-gke:
    image: ghcr.io/nvidia/skyhook-packages/nvidia-tuning-gke
    version: 0.1.0
    interrupt:
      type: service
      services:
        - systemd-sysctl
    configMap:
      accelerator: gb200
      intent: inference
```

## Baked-in profiles

Profiles are grouped by accelerator then intent: `profiles/{accelerator}/{intent}/`. Each profile directory contains `sysctl.conf` and optionally `service_containerd.conf`. No grub (GKE does not use grub). Content matches [tuning/examples/](../tuning/examples/) sysctl (and service_containerd for GB200):

- **profiles/h100/inference/** – Base ARP + sched (sysctl).
- **profiles/h100/multiNodeTraining/** – Base ARP + net/tcp/bbr/fq (sysctl).
- **profiles/gb200/inference/** – Base + gb200-perf + sched (sysctl); containerd LimitSTACK.
- **profiles/gb200/multiNodeTraining/** – Base + gb200-perf + net/tcp (sysctl); containerd LimitSTACK.

Adding a new accelerator or intent is done by adding a new directory under `profiles/`; the prepare script discovers them at runtime.

## What is not applied

Due to Container Optimized OS the following limitations apply: no CPU governor, no kernel module loading, no dynamic `isolcpus` (add a concrete `isolcpus=` line to the profile and rebuild if needed).

## Version

- **Package version:** 0.1.0
- **Base package:** tuning (1.1.4)
- **Schema version:** v1
