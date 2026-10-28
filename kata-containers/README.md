# Kata Containers package

The `kata-containers` package in `kata-containers/` supports
only `qemu-nvidia-cpu-runtime-rs`, registered with containerd as
`kata-qemu-nvidia-cpu-runtime-rs`. It uses EROFS memory mode and dm-verity,
and the default `/opt/kata` paths. It discovers standalone containerd, K3s,
RKE2, MicroK8s and k0s automatically. The package does not invoke kubeadm.
CRI-O is not supported by this CPU/EROFS adapter.

The node needs Linux amd64/arm64, systemd, KVM, containerd >= 2.3 and
`erofs-utils >= 1.8.2`. GPU Operator, NFD, kata-device-provisioner,
kata-device-plugin, and nydus are not dependencies of this CPU package.
End-to-end validation covers Ubuntu 26.04 arm64 with kubeadm, K3s, RKE2 and
k0s. MicroK8s 1.36.2 was tested but its bundled containerd 2.2.3 and erofs-utils
1.4 cannot run this profile. The package rejects containerd < 2.3 before changing
CRI configuration. amd64 CPU guest execution is not yet validated.

Stock Ubuntu 24.04 is insufficient: its
[erofs-utils 1.7.1 package](https://packages.ubuntu.com/noble/erofs-utils)
lacks the required `mkfs.erofs` options. Use Ubuntu 26.04 for the validated path.
Using 24.04 requires separately provisioning compatible erofs-utils and
containerd versions. This package checks prerequisites through kata-deploy's
host-check stage; it does not upgrade the host's erofs-utils or containerd.

## Package versions are Kata versions

```bash
docker build kata-containers \
  -t <your-registry>/nodewright-packages/kata-containers:4.3.1
docker push <your-registry>/nodewright-packages/kata-containers:4.3.1
```

The checked-in `config.json` uses the Kata release as `package_version`, so
the repository's validation and release tooling can read it directly. The build
checks this version against `/opt/kata-artifacts/VERSION` from the pinned Kata
image. A mismatch fails the build. There is no independent adapter version.

For a new Kata release, update `config.json` and the pinned Kata image together.
Release tags follow the repository convention: `kata-containers/4.3.1`. Released
images use `ghcr.io/nvidia/nodewright-packages/kata-containers:<kata-version>`.
The deployment manifests below use this official repository.
The initial package has not been released yet. For a POC before publication,
build and publish to your own registry and set `image` in the NodeWright manifest.

Use the Kata version for the published image tag and NodeWright package
`version`. Rebuilds of the same release can retain that version and use
NodeWright's `containerSHA` to pin the package image. Configuration changes still
reconcile at the same version.

The package uses the agent configured by the installed NodeWright chart. The
Dockerfile checks that kata-deploy exposes every finite command used by the
adapter.

## Install

Use [nodewright.yaml](nodewright.yaml) and
[nvidia-cpu-runtimeclass.yaml](nvidia-cpu-runtimeclass.yaml) for both amd64 and
arm64 nodes. The manifests use the official multi-architecture package image
and need no edits for the default setup once that image is published. Before
publication, set `image` to your own published package repository. A mixed
architecture group needs an image published for both amd64 and arm64.

The package discovers the host distribution and queries its containerd socket
using the distribution's client. It passes the running server version to
kata-deploy without requiring Kubernetes API access or an administrator-supplied
version. `CONTAINER_RUNTIME_VERSION` remains an optional override.

On a single-node POC, configure the operator's pod tolerations to include
`node.kubernetes.io/unschedulable:NoSchedule` and the runtime-required taint
before applying the package. This keeps the controller running while NodeWright
drains its node. Keep two
controller replicas with the chart's default `minAvailable: 1` disruption
budget; both replicas can run on the same node.

The manifest enables `runtimeRequired` and `autoTaintNewNodes`. Before adding
an existing node to the group, apply the runtime-required taint; also configure
future pool nodes to join with it. This holds ordinary workloads until every
runtime-required NodeWright targeting the node completes. Use the taint configured
by your operator; the commands below use its default. Do not give Kata workloads
a toleration for this taint.

From the repository root, taint and label each target node, then apply the files:

```bash
kubectl taint node <node> nodewright.nvidia.com=runtime-required:NoSchedule --overwrite
kubectl label node <node> nodewright.nvidia.com/kata-profile=kata-containers
kubectl apply -f kata-containers/smoke-rbac.yaml \
  -f kata-containers/nvidia-cpu-runtimeclass.yaml \
  -f kata-containers/nodewright.yaml
kubectl wait --for=condition=Ready nodewright/kata-containers --timeout=20m
```

Workloads on either architecture use
`runtimeClassName: kata-containers-qemu-nvidia-cpu-runtime-rs`, backed by the
`kata-qemu-nvidia-cpu-runtime-rs` containerd handler. The NodeWright selects
Linux amd64 and arm64 nodes. The RuntimeClass selects the stable group label,
so pausing the NodeWright or beginning a rollout does not remove already
installed nodes from its scheduling pool. The runtime-required taint gates new
installations. Provision only supported architectures in that pool; an
unsupported node must stay tainted and will not be configured by this package.
Only arm64 has been validated end to end.

`autoTaintNewNodes` is a fallback with a scheduling race before reconciliation.
It does not re-taint nodes already handled by NodeWright, including after a
reset. Pre-taint existing nodes and future pool nodes rather than relying on
this fallback. See NodeWright's
[runtime-required behavior](https://github.com/NVIDIA/nodewright/blob/main/docs/user-guide/runtime-required.md).

An existing node pool works too: replace the NodeWright's
`nodewright.nvidia.com/kata-profile` selector with the pool's existing label,
and the RuntimeClass's group selector, keeping the Linux selectors and the
NodeWright's architecture expression. For example, the NodeWright selector is:

```yaml
nodeSelectors:
  matchLabels:
    kubernetes.io/os: linux
    your-domain.example/node-pool: kata-workers
  matchExpressions:
    - key: kubernetes.io/arch
      operator: In
      values: [amd64, arm64]
```

Use your cluster's actual pool label key and value. Existing and future nodes
with that label are selected automatically; no extra Kata label is needed.
Set the RuntimeClass's `scheduling.nodeSelector` to the same `matchLabels` map.
Configure the pool to join with the runtime-required taint before exposing the
RuntimeClass to workloads.

Nodes in one group share the package version and configuration. The containerd
version is detected separately on each node. To create another group, copy
both manifests and change the NodeWright name, RuntimeClass name, and
`nodewright.nvidia.com/kata-profile` value in both selectors. A single-valued group label keeps
installations disjoint. Uninstall before moving an already installed node to
another group. Do not run two installations managing `/opt/kata` on the same
node.

Keep `fieldRef.apiVersion: v1` on `NODE_NAME`: API defaulting can otherwise
cause a pod-comparison mismatch with the tested operator. The operator already
supplies `COPY_RESOLV=false`; the package does not override it.

## Kubernetes distributions

No distribution parameter is required for normal installations. The host
wrapper recognizes active K3s, RKE2, MicroK8s and k0s systemd services and uses
standalone containerd otherwise. It retains the resolved distribution, config
directory, socket and server version in NodeWright's stable state directory
so a new uninstall generation can reuse the installation's settings.

| Distribution | Host containerd configuration directory | Containerd socket |
| --- | --- | --- |
| Standalone | `/etc/containerd` | `/run/containerd/containerd.sock` |
| K3s | `/var/lib/rancher/k3s/agent/etc/containerd` | `/run/k3s/containerd/containerd.sock` |
| RKE2 | `/var/lib/rancher/rke2/agent/etc/containerd` | `/run/k3s/containerd/containerd.sock` |
| MicroK8s | `/var/snap/microk8s/current/args` | `/var/snap/microk8s/common/run/containerd.sock` |
| k0s | `/etc/k0s` | `/run/k0s/containerd.sock` |

These host directories are mounted at `/etc/containerd` in the private
installer namespace. Kata's existing finite stages select the distro-specific
config/template, service and kubelet-root settings. K3s/RKE2 restart their
server or agent service; MicroK8s uses its snap containerd service. k0s loads
runtime drop-ins dynamically and Kata does not restart its service.

For K3s/RKE2, the running generated config must already import the applicable
`config.toml.d` or `config-v3.toml.d` directory. Kata rejects a missing import
rather than replacing the distribution's generated config or template. See
[K3s configuration](https://docs.k3s.io/advanced) and
[RKE2 configuration](https://docs.rke2.io/advanced).

For nonstandard layouts, package `env` can optionally set:

- `K8S_DISTRIBUTION`: `k8s`, `k3s`, `rke2`, `microk8s` or `k0s`; unset or `auto` discovers it.
- `CONTAINERD_CONFIG_DIR`: an absolute host configuration directory.
- `CONTAINERD_RUNTIME_SOCKET`: an absolute socket path or `unix:///...` URI.

These are package settings, not new NodeWright API fields. They are unnecessary
for the defaults in the table. Uninstall using the old settings before changing
them on an installed node. All distributions still need the host versions and
kernel capabilities listed above; a distribution's bundled containerd may be
too old for this EROFS profile. The dm-verity settings used here require
containerd >= 2.3, even though older containerd releases support basic EROFS.
MicroK8s also resolves tools inside its snap: installing newer erofs-utils on
the host does not replace an older bundled `mkfs.erofs`. A MicroK8s build must
provide compatible containerd and erofs-utils before using this package.

## Containerd configuration file

The default is `/etc/containerd/config.toml`. To use another file in the same
directory, including a DPU-specific configuration, set its filename in the
NodeWright package's `env` entry:

```yaml
- name: CONTAINERD_CONFIG_FILE_NAME
  value: config-dpu.toml
```

Kata uses it for installation and uninstall on standalone containerd. Absolute
paths and directory components are rejected. Use the file the host's containerd
service actually loads. This setting does not change containerd's startup
arguments, service name or socket. Other distributions select their own config
or template filename and reject a custom basename.
Before changing this value on an installed node, uninstall with the old value
so its configuration can be cleaned up, then install with the new value.

## Configuration and lifecycle

The adapter explicitly selects the NVIDIA CPU Rust shim and EROFS. The
`containerd-user-dropin.toml` ConfigMap key disables host fs-verity for broad
host filesystem compatibility, matching Kata's NVIDIA profile; guest dm-verity
remains enabled. Runtime overrides use
`dropin-qemu-nvidia-cpu-runtime-rs.toml`.

Apply/upgrade runs Kata's SELinux-policy stage, which skips installation when
SELinux is disabled, loads the required kernel modules and runs Kata's native
host prerequisite check. Its paired check repeats the
host check before proceeding. The config stage runs the finite installer, including when ConfigMap values change without a Kata version bump.
Keep both the package's `noop` interrupt and its wildcard `configInterrupts`
entry so host changes run through NodeWright's cordon/drain flow. Kata-deploy
performs the actual containerd restart. The interruption budget defaults to
one node.

The package checks for the Rust shim and CPU configuration. Post-interrupt
then creates a temporary pod using the Kata RuntimeClass on that same node,
waits for successful guest execution, deletes the pod and confirms its removal.
Only then does it record smoke-test success and remove the staged installer.
The paired check requires that success record and staging cleanup. A failed
pod, timeout, API error or unconfirmed deletion blocks NodeWright completion
and release of the runtime-required taint. Cleanup is attempted on failure too.
The smoke pod uses explicit node placement, so it can run while the node is
cordoned and carries a NoSchedule installation taint.
Uninstall removes its staged installer after the native cleanup succeeds;
failed stages retain the payload for diagnosis. NodeWright's init container
copies the package again before a later lifecycle Job, so reconciliation and
uninstall do not depend on retaining old staged payloads. This smoke test
exercises the runtime, guest agent and snapshotter; platform
configuration and hardening review remains a separate adoption requirement.

## Uninstall

Delete workloads using this RuntimeClass before requesting uninstall:

```bash
kubectl patch nodewright <group-name> --type=merge \
  -p '{"spec":{"packages":{"kata-containers":{"uninstall":{"enabled":true,"apply":true}}}}}'
```

Kata-deploy reverts CRI configuration and restarts containerd before removing
artifacts. Verify the handler and Rust shim are absent and the node remains
Ready. Uninstall is also enabled on resource deletion. The RuntimeClass is
managed separately and should be removed after cleanup. Reapplying with
`uninstall.apply: false` reinstalls the package.

## Implementation and checks

The package follows NodeWright's standard host-step mechanism (`on_host: true`).
It contains no agent binary and does not override the operator's agent image.
NodeWright copies the scripts, installer filesystem and compressed Kata artifacts
into its package directory on the host. The build retains only the component
tarballs required by the CPU runtime on the target architecture, using Kata's
component catalog. Allow temporary disk space for this staged payload in
addition to the installed runtime; it is removed after successful validation.

Host steps require Bash, systemd, `unshare`, `mount`, `chroot`, `awk` and a
containerd client. K3s, k0s and MicroK8s can supply their own `ctr` subcommand;
RKE2's bundled client is preferred over a host-installed `ctr`. The wrapper enters a
private mount namespace and runs the bundled installer in a chroot, with the host
and ConfigMap files mounted at kata-deploy's expected paths. The namespace's
mounts disappear when the step exits. The privileged package retains full host
access; the chroot is an execution environment, not a security boundary.
The installer stages need no Kubernetes API permissions. The smoke gate uses
the dedicated service account and token Secret in [smoke-rbac.yaml](smoke-rbac.yaml).
Its Role permits only pod get/create/delete in the isolated
`kata-containers-smoke` namespace, which enforces the restricted Pod Security
Standard. The guest pod has no API token, runs as a non-root user and drops all
capabilities. API credentials live only in a private tmpfs during the check.
If the operator uses a namespace other than `nodewright`, update the service
account, Secret and RoleBinding subject namespaces in that manifest.

The default smoke image is the multi-architecture BusyBox 1.37.0 image pinned
by digest. Its memory limit is 2 GiB to allow the NVIDIA guest to boot.
`KATA_SMOKE_IMAGE` can select an approved mirror providing
`/bin/uname`. Set `KATA_SMOKE_RUNTIME_CLASS` for a renamed RuntimeClass.
`KATA_SMOKE_TIMEOUT` defaults to 300 seconds and
`KATA_SMOKE_CLEANUP_TIMEOUT` to 60 seconds. These are safety deadlines, not
installation performance targets. Kubernetes API endpoint variables default to
the pod's service environment; the manifest supplies CA and token values from
the dedicated Secret. Remove this shared RBAC and namespace only after all
Kata groups using them have been uninstalled.

Run from the repository root:

```bash
make validate-standalone PACKAGE=kata-containers
make test-package PACKAGE=kata-containers
```

Tests in `tests/integration/kata_containers` use the existing pytest and
`DockerTestRunner` harness. Lifecycle tests stub host commands inside test
containers; they do not modify the host or boot a Kata guest. The repository's
existing package discovery includes this package in validation, tests and builds.

Tests cover Kata version agreement and mismatch rejection, CPU-only manifests,
configuration reconciliation, distribution discovery and host mounts, saved
uninstall settings, target ELF architectures, and lifecycle failure handling.
TLS API fixtures exercise guest success, timeout, interruption, retries, pod
ownership and deletion failures without booting a guest.
