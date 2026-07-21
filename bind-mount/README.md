# Bind Mount Package

The `bind-mount` package exposes one existing host mount at a second stable path through a persistent systemd bind mount. It does not discover, format, assemble, or delete storage.

The package is intended for nodes where platform bootstrap owns the source filesystem and a workload needs a stable path. It validates the source in the host mount namespace, writes and enables a systemd mount unit, and relies on a NodeWright interrupt to activate the unit before workloads resume.

## Configuration

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: local-data-bind
spec:
  runtimeRequired: true
  interruptionBudget:
    count: 1
  packages:
    bind-mount:
      version: 0.1.1
      image: ghcr.io/nvidia/nodewright-packages/bind-mount
      interrupt:
        type: reboot
      configMap:
        source: /mnt/k8s-disks/0
        target: /mnt/data
        expected-source-fstype: xfs
        expected-source-device-prefix: /dev/md
```

`source` and `target` are required. `expected-source-fstype` and `expected-source-device-prefix` are optional fail-closed assertions.

The image may be referenced under multiple package map keys on the same node to
manage multiple bind mounts. Each instance has its own ownership receipt and
owner marker, scoped to the Skyhook resource UID and package map key. Targets
must be distinct: two instances that name the same systemd mount unit fail
closed rather than sharing or replacing it.

## Safety contract

- The source must already be an exact, read-write mount point.
- The target must be empty, or already be the same bind mount backed by this package instance's owned unit; otherwise the package fails.
- The systemd unit rechecks target emptiness at activation and fails if the target is already non-empty, reducing the risk of silently hiding newly written data.
- Existing symlinks, foreign systemd units, and `/etc/fstab` ownership are rejected.
- Source and target paths must be disjoint; neither may contain the other.
- Prepared and active checks reject a read-only target mount.
- A source or target configuration change fails while that instance's old target remains mounted. Remove the package and recycle the node before changing paths.
- Uninstall disables and removes the persistent unit but deliberately does not unmount a live target. Recycle the node to complete rollback safely.
- A root-only ownership receipt supports ConfigMap-less uninstall on operators older than v0.16.0 and preserves cleanup after an interrupted install on newer operators. The receipt is removed after `uninstall-check` confirms that no owned unit remains.
- Uninstall of a package instance that never installed succeeds as a clean no-op, even when the uninstall runs without a ConfigMap. It only sweeps units carrying that exact Skyhook-resource/package-key owner marker and cannot remove another instance's unit.
- The mount unit rechecks during boot that the source is itself a read-write mount point. This prevents an existing source directory on the root filesystem from being accepted when the source mount definition is missing or fails.
- The mount unit is installed as a required dependency of `kubelet.service` and `snap.kubelet-eks.daemon.service`, and it orders before both. The lifecycle checks verify that both dependency links resolve to the owned mount unit. If the mount cannot start during boot, kubelet remains down instead of admitting workloads onto the unmounted target. The post-interrupt check remains the controlled-activation gate.
- The kubelet dependency is a start-up gate, not a continuous runtime binding. An unexpected unmount after kubelet has started requires external invariant monitoring and immediate workload containment; consumers should alert whenever a Ready node no longer has the expected target mount.

The apply and config checks validate the prepared unit before an interrupt. The post-interrupt check validates the active host mount. Consumers should use `runtimeRequired: true` and a bounded interruption budget.
