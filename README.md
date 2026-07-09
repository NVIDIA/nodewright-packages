# NodeWright Packages

*Formerly known as Skyhook Packages*

This repository contains pre-built packages for the [NVIDIA NodeWright Operator](https://github.com/NVIDIA/skyhook), a Kubernetes-aware package manager for cluster administrators to safely modify and maintain underlying hosts declaratively at scale.

> **Note:** NodeWright is being renamed from Skyhook. Code, CRDs, Helm charts, and CLI commands still use `skyhook` for now. The rename will roll out incrementally to avoid breaking changes.

## Overview

NodeWright packages follow a well-defined lifecycle with multiple stages (apply, config, interrupt, post-interrupt, upgrade, uninstall) that ensure proper installation, configuration, and management of node-level changes. Each package in this repository implements these lifecycle stages according to its specific purpose.

For detailed information about package lifecycle stages, see [PACKAGE_LIFECYCLE.md](./PACKAGE_LIFECYCLE.md).

## Available Packages

### 1. Shellscript Package (`shellscript/`)
A versatile package that allows you to run arbitrary bash scripts defined in your NodeWright Custom Resource configMaps.

**Capabilities:**
- Execute custom bash scripts during any lifecycle stage
- Full lifecycle support (apply, config, post-interrupt, uninstall with checks)
- Configurable through configMaps
- Useful for custom automation and system modifications

**Example use cases:**
- Custom software installation
- System configuration changes
- File management operations
- Service management tasks

### 2. Tuning Package (`tuning/`)
A specialized package for system-level tuning and configuration management.

**Capabilities:**
- System service configuration via drop-in files
- Kernel parameter tuning (sysctl)
- User limit configuration (ulimits)
- Container runtime limit configuration
- GRUB configuration management
- Support for different interrupt types based on configuration changes

**Supported configuration types:**
- `grub.conf` - GRUB kernel parameters (requires reboot)
- `sysctl.conf` - Kernel parameters (requires reboot or service restart)
- `ulimit.conf` - User limits (immediate effect + container limits on reboot)
- `service_{name}.conf` - Systemd service configurations (requires service restart)

### 3. Tuned Package (`tuned/`)
A package for managing the tuned system tuning daemon on Linux systems for automated performance optimization.

**Capabilities:**
- Multi-distribution support (Ubuntu/Debian, CentOS/RHEL/Amazon Linux, Fedora)
- Automated tuned package installation and service management
- Custom tuned profile deployment via configmaps
- Built-in profile validation and verification
- Handles necessary interrupts for tuning parameters that require reboots/restarts
- Comprehensive installation and configuration validation

**Key features:**
- Deploy custom tuned profiles from configmaps
- Apply system-wide performance tuning profiles
- Automatic service lifecycle management (install, configure, validate, uninstall)
- Support for built-in profiles (balanced, powersave, throughput-performance, etc.)
- Idempotent operations safe for repeated execution

### 4. Kdump Package (`kdump/`)
A package for automated installation and configuration of kdump crash dump collection on Linux systems.

**Capabilities:**
- Multi-distribution support (Ubuntu/Debian, CentOS/RHEL/Amazon Linux, Fedora)
- Automated kdump package installation and service management
- Crashkernel parameter configuration in GRUB
- Custom kdump configuration deployment via configmaps
- Comprehensive validation and health checks
- Safe uninstallation with complete cleanup

**Key features:**
- Configure kernel crash dump functionality for debugging system failures
- Automatic crashkernel memory reservation in GRUB
- Support for custom kdump.conf configurations
- Post-interrupt validation of crash kernel functionality
- Complete lifecycle management (install, configure, validate, uninstall)

### 5. NVIDIA Setup Package (`nvidia-setup/`)
A package that applies the same node setup steps as the dgxcloud_aws_eks VMI for selected (service, accelerator) combinations. Runs after the machine is up (NodeWright on a live node).

**Capabilities:**
- Opinionated defaults per (service, accelerator) with optional env overrides (EIDOS_KERNEL, EIDOS_EFA, EIDOS_LUSTRE)
- Apply: upgrade, EFA driver, Lustre client, chrony, setup-local-disks (install and run); reboot may be required after apply
- Apply-check: validate all steps for the selected combination are complete
- Supported combinations: eks-h100, eks-gb200 (extensible via case + functions in apply.sh / apply_check.sh)

**Key features:**
- ConfigMap: `service` and `accelerator` only; versions baked in `defaults/*.conf`
- No OFI, hardening, or system-node-settings; see [nvidia-setup README](./nvidia-setup/README.md)

### 6. NVIDIA Tuning GKE Package (`nvidia-tuning-gke/`)
Extends the **tuning** package with baked-in H100 and GB200 configs for GKE Container Optimized OS. You supply only `accelerator` and `intent`; the package selects the matching sysctl (and optional containerd drop-in) and runs the base tuning apply. No grub—GKE nodes do not use grub. Note: this is a limited set from nvidia-tuned due to the limitations of the mainly read-only OS. For non COS GKE setups consider updating nvidia-tuned to support gke and use the base profiles.

**Capabilities:**
- Sysctl and service drop-ins derived from [nvidia-tuned](./nvidia-tuned/)
- ConfigMap: `accelerator` (h100, gb200) and `intent` (inference, multiNodeTraining)
- Baked-in profiles under `profiles/{accelerator}/{intent}/`

**Key features:**
- No manual sysctl.conf authoring; profile content is fixed in the image
- See [nvidia-tuning-gke README](./nvidia-tuning-gke/README.md)

### 7. Copy-Fail Package (`copy-fail/`)
A temporary mitigation package for **CVE-2026-31431 ("Copy Fail")** that disables the vulnerable `algif_aead` kernel module.

**Capabilities:**
- Writes `/etc/modprobe.d/disable-algif.conf` to prevent `algif_aead` from loading at boot
- Best-effort `rmmod algif_aead` for the running kernel (tolerates the module being in use)
- Strict `config-check` that loudly fails when `algif_aead` is still loaded; opt-out via `ALLOW_LOADED_MODULE=true`
- Clean uninstall that removes the modprobe blacklist file

**Key features:**
- Distro-agnostic (works anywhere `kmod`/`modprobe` is honored)
- No reboot, no configmap, no interrupts: minimal surface area
- Designed to be retired once distros ship a fixed kernel

### 8. Bind Mount Package (`bind-mount/`)

A fail-closed package that exposes an existing host mount at a stable second path through a persistent systemd bind mount.

**Capabilities:**
- Validates the exact source mount, filesystem type, device prefix, and read-write state
- Refuses to hide nonempty target data or replace foreign mount definitions
- Activates through a controlled NodeWright interrupt and verifies the host mount afterward
- Removes persistence on uninstall without live-unmounting active workloads

## Package Structure

Each package follows the standard NodeWright package structure:

```
[package name]
├── Dockerfile
├── config.json
├── README.md
├── root_dir/
│   └── ... (files copied to root filesystem)
└── skyhook_dir/
    └── ... (scripts and static files used by package)
```

### Key Components

- **`skyhook_dir/`**: Contains scripts used in lifecycle stages and any static files referenced by scripts
  - These are copied onto the host at `${STEP_ROOT}`
- **`root_dir/`**: Files copied directly to the root filesystem at /
  - `root_dir/foo/bar.txt` will end up at `/foo/bar.txt`
- **`config.json`**: Package configuration that must comply with the [skyhook agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1)
- **`Dockerfile`**: Copies package components to `/skyhook-package` in the container
  - Everything in `/skyhook-package` in the container ends up at `${SKYHOOK_DIR}` on the host file system

### Available metadata for scripts when being executed as a part of the NodeWright package
- **`STEP_ROOT`**: An environment variable, the directory where the `skyhook_dir/` folder is copied to
- **`SKYHOOK_DIR`**: An environment variable, the directory where `/skyhook-package` is copied to
- **`${SKYHOOK_DIR}/configmaps`**: Directory where all the configmaps for the package will be
- **`${SKYHOOK_DIR}/node-metadata`**: Directory of metadata related to the node
  - `${SKYHOOK_DIR}/node-metadata/labels.json`: json of all the labels on the node when the package was scheduled
  - `${SKYHOOK_DIR}/node-metadata/annotations.json`: json of all the annotations on the node when the package was scheduled
  - `${SKYHOOKD_DIR}/node-metadata/packages.json`: Packages that have run on the node so far. `{'agent': <version>: 'packages: [{'name': str, 'version': str, 'image': str}, ...]}`

## Building Packages

To build a package for multi-architecture deployment:

1. Create a builder instance:
   ```bash
   docker buildx create --name builder --use
   ```

2. Build and push the package:
   ```bash
   docker buildx build -t {package}:{tag} \
     -f {dockerfile} \
     --platform=linux/amd64,linux/arm64 \
     --push {package_directory}
   ```

Example:
```bash
docker buildx build -t ghcr.io/nvidia/skyhook-packages/shellscript:1.1.1 \
  -f shellscript/Dockerfile \
  --platform=linux/amd64,linux/arm64 \
  --push shellscript/
```

## Using Packages

Packages are used by creating NodeWright Custom Resources that reference the package images. Here's a basic example:

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: example-package
spec:
  nodeSelectors:
    matchLabels:
      skyhook.nvidia.com/node-type: worker
  packages:
    my-package:
      version: 1.1.1
      image: ghcr.io/nvidia/skyhook-packages/shellscript:1.1.1
      configMap:
        apply.sh: |
          #!/bin/bash
          echo "Package applied successfully"
        apply_check.sh: |
          #!/bin/bash
          echo "Package installation verified"
```

For detailed usage examples, see the README files in each package directory.

## Package Lifecycle

All packages in this repository implement the NodeWright lifecycle stages:

1. **Apply** - Initial installation and setup
2. **Config** - Handle configuration changes
3. **Interrupt** - Handle service restarts/reboots when needed
4. **Post-Interrupt** - Validation after interrupts
5. **Upgrade** - Handle version upgrades
6. **Uninstall** - Clean removal of components

The lifecycle ensures that packages are applied safely with minimal disruption to running workloads. See [PACKAGE_LIFECYCLE.md](./PACKAGE_LIFECYCLE.md) for comprehensive documentation.

## Repository Rules

This repository follows strict development practices:

### Commit Format
All commits MUST use conventional commit format with the package name as scope:

- `feat(shellscript): Add support for upgrade stage`
- `fix(tuning): Post-interrupt check for containerd changes did not allow infinity setting`
- `docs(general/ci): Update the main README.md for CI workflow`

### Versioning
- Package versions MUST follow [Semantic Versioning](https://semver.org/)
- Tags are package-specific: `{package}/{version}` (e.g., `shellscript/1.1.1`)
- CI automatically builds packages on tag creation

### Development Workflow
1. Make changes to package code and configuration
2. Update package version in `config.json`
3. **Validate package configuration** against the [official schemas](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1)
4. Test package functionality
5. Commit with conventional format
6. Create version tag
7. CI builds and publishes package automatically

### Schema Validation

All packages must have a valid `config.json` that complies with the skyhook agent JSON schemas. The skyhook-agent includes built-in validation tooling:

```bash
# Validate your package configuration before publishing
skyhook-agent validate /path/to/your/config.json
```

This validation step is crucial as the agent uses JSON schema validation to ensure package configurations are correct before execution.

## Getting Started

1. **Choose a package** that fits your use case:
   - `shellscript` for custom scripts and automation
   - `bind-mount` for a persistent alias to an existing host filesystem
   - `tuning` for system-level configuration management  
   - `tuned` for automated performance tuning with the tuned daemon
   - `kdump` for kernel crash dump collection and debugging
2. **Review the package README** for specific usage instructions and examples
3. **Create a NodeWright Custom Resource** referencing the package
4. **Apply the resource** to your cluster and monitor the package deployment
5. **Verify the package status** using `kubectl describe skyhooks`

## Documentation

- [Package Lifecycle Documentation](./PACKAGE_LIFECYCLE.md) - Comprehensive guide to package lifecycle stages
- [Shellscript Package](./shellscript/README.md) - Usage guide for the shellscript package
- [Tuning Package](./tuning/README.md) - Usage guide for the tuning package
- [Tuned Package](./tuned/README.md) - Usage guide for the tuned package
- [Kdump Package](./kdump/README.md) - Usage guide for the kdump package
- [NVIDIA Setup Package](./nvidia-setup/README.md) - Node setup (EFA, Lustre, chrony, local disks) per service/accelerator
- [Copy-Fail Package](./copy-fail/README.md) - CVE-2026-31431 modprobe-blacklist mitigation
- [Bind Mount Package](./bind-mount/README.md) - Persistent, fail-closed bind mounts for existing host storage
- [NVIDIA NodeWright Documentation](https://github.com/NVIDIA/skyhook) - Main NodeWright operator documentation

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on contributing to this repository.

## License

This project is licensed under the terms specified in [LICENSE](./LICENSE).
