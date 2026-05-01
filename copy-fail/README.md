# Copy-Fail Package

This NodeWright Package applies the temporary mitigation for **CVE-2026-31431 ("Copy Fail")** as published in [CERT-EU advisory 2026-005](https://cert.europa.eu/publications/security-advisories/2026-005/).

> **Temporary mitigation only.** This package is expected to be retired once distributions ship a fixed kernel. When that happens, remove the package from your SCR; the uninstall stage will clean up `/etc/modprobe.d/disable-algif.conf`.

## What it does

CVE-2026-31431 is a vulnerability in the Linux kernel's `algif_aead` module (the AF_ALG userspace AEAD interface). The advisory's recommended workaround is to disable the module:

- `config` writes `/etc/modprobe.d/disable-algif.conf` containing `install algif_aead /bin/false`, then attempts a best-effort `rmmod algif_aead`. If the module is in use, the rmmod is skipped — the blacklist will fully take effect on the next reboot.
- `config-check` (strict by default) verifies the blacklist file is in place AND that `algif_aead` is not currently loaded. If the file is correct but the module is still loaded, it exits non-zero with a loud message indicating the node is still vulnerable until reboot.
- `uninstall` removes `/etc/modprobe.d/disable-algif.conf`. It does **not** proactively `modprobe algif_aead`; the kernel will autoload it on demand if anything needs it.
- `uninstall-check` verifies the file is gone.

The package does **not** force a reboot. If you need guaranteed eviction of a busy module, pair this package with a planned drain + reboot.

## Tunables

### `ALLOW_LOADED_MODULE` (env var on `config-check`)

Default `"false"`. When `"true"`, `config-check` exits 0 even if `algif_aead` is still loaded — useful on nodes where the loaded-module case has been accepted while you wait for a planned reboot.

Override per-node via the SCR's `env` map on the `config-check` mode.

## Out of scope

The advisory's secondary recommendation — blocking `AF_ALG` socket creation via seccomp on containerised workloads — is **not** handled by this package. That control belongs in workload manifests / runtime configuration. This package only addresses the host-level modprobe blacklist.

## Example NodeWright Custom Resource

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: copy-fail-mitigation
spec:
  nodeSelectors:
    matchLabels:
      skyhook.nvidia.com/node-type: worker
  packages:
    copy-fail:
      version: 1.0.0
      image: ghcr.io/nvidia/skyhook-packages/copy-fail:1.0.0
```

To silence the strict check on a node where the module is still loaded:

```yaml
    copy-fail:
      version: 1.0.0
      image: ghcr.io/nvidia/skyhook-packages/copy-fail:1.0.0
      env:
        config-check:
          ALLOW_LOADED_MODULE: "true"
```

## Files written and removed

| Stage | File | Action |
|---|---|---|
| `config` | `/etc/modprobe.d/disable-algif.conf` | created (`install algif_aead /bin/false`) |
| `config` | (kernel module) | best-effort `rmmod algif_aead` |
| `uninstall` | `/etc/modprobe.d/disable-algif.conf` | removed |

## Distribution support

The package is distro-agnostic. `/etc/modprobe.d/*.conf` is honored by every mainstream Linux distribution that uses `kmod` / `modprobe`, which covers all distros listed in the advisory (Ubuntu 20.04–24.04 LTS, Amazon Linux 2023, RHEL 10.1, SUSE 16, and their kernel build family).

## Retire path

Once your distro ships a fixed kernel:

1. Update kernels on affected nodes.
2. Remove `copy-fail` from your SCR. The uninstall stage will remove `/etc/modprobe.d/disable-algif.conf`.
3. The kernel will autoload `algif_aead` on demand if anything needs it.
