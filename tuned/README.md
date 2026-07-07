# Tuned Package

A NodeWright package for managing the `tuned` system tuning daemon on Linux systems. This package provides automated installation, configuration, and management of tuned profiles for system performance optimization.

## Overview

[Tuned](https://github.com/redhat-performance/tuned) is a daemon that uses udev to monitor connected devices and statically and dynamically tunes system settings according to a selected profile. This package automates the deployment and configuration of tuned across different Linux distributions.

## Features

- **Multi-distribution support**: Works on Ubuntu/Debian, CentOS/RHEL/Amazon Linux, and Fedora
- **Custom profile management**: Deploy and apply custom tuned profiles via configmaps
- **Idempotent operations**: Safe to run multiple times without side effects
- **Comprehensive validation**: Built-in checks for installation and configuration status
- **Service lifecycle management**: Handles installation, configuration, and uninstallation
- **Handles Necessary Interrupts**: Handles reboots and service restarts around important workloads for specific tuning parameters that require it.

## Package Structure

```
tuned/
├── config.json                           # NodeWright package configuration
├── README.md                            # This file
├── Dockerfile                           # Container build file
└── skyhook_dir/
    ├── install_tuned.sh                 # Install tuned package and service
    ├── install_tuned_check.sh           # Validate tuned installation
    ├── uninstall_tuned.sh               # Remove tuned package and service
    ├── uninstall_tuned_check.sh         # Validate tuned removal
    ├── apply_tuned_profile.sh           # Apply tuned profiles from configmaps
    ├── apply_tuned_profile_check.sh     # Validate profile configuration
    └── post_interrupt_tuned_check.sh    # Validate post-interruption state
```

## Supported Operating Systems

- **Ubuntu/Debian**: Uses `apt` package manager
- **CentOS/RHEL/Amazon Linux**: Uses `yum` package manager
- **Fedora**: Uses `dnf` package manager

## Package Modes

### Installation Modes

#### `apply` / `upgrade`
- **Script**: `install_tuned.sh`
- **Purpose**: Installs the tuned package and starts/enables the service
- **Actions**:
  - Updates package repositories
  - Installs tuned package
  - Enables and starts tuned service
  - Displays service status

#### `apply-check` / `upgrade-check`
- **Script**: `install_tuned_check.sh`
- **Purpose**: Validates successful tuned installation
- **Checks**:
  - `tuned` command availability
  - `tuned-adm` command availability
  - Service is running (`systemctl is-active`)
  - Service is enabled for boot (`systemctl is-enabled`)

### Configuration Mode

#### `config`
- **Script**: `apply_tuned_profile.sh`
- **Purpose**: Deploys custom profiles and applies the specified tuned profile
- **Process**:
  1. Creates custom profile directories in the tuned profiles dir (`/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)
  2. Copies configmap files as `tuned.conf` for each custom profile
  3. Reads the target profile from `tuned_profile` configmap file
  4. Applies the specified profile using `tuned-adm profile`

#### `config-check`
- **Script**: `apply_tuned_profile_check.sh`
- **Purpose**: Validates profile configuration
- **Checks**:
  - Tuned service is running
  - Configmaps directory exists
  - Custom profiles are properly deployed
  - Correct profile is active and verified
  - Profile verification via `tuned-adm verify` (behavior controlled by `INTERRUPT` variable)

### Uninstallation Mode

#### `uninstall`
- **Script**: `uninstall_tuned.sh`
- **Purpose**: Removes tuned package and disables service
- **Actions**:
  - Disables and stops tuned service
  - Removes tuned package
  - Cleans up unused dependencies (apt only)

#### `uninstall-check`
- **Script**: `uninstall_tuned_check.sh`
- **Purpose**: Validates successful tuned removal
- **Checks**:
  - `tuned` command is not available
  - `tuned-adm` command is not available
  - Service is stopped
  - Service is disabled

## Recovery Mode

#### `post-interrupt-check`
- **Script**: `post_interrupt_tuned_check.sh`
- **Purpose**: Validates system state after interrupt (reboot/service restart)
- **Checks**: Performs comprehensive validation of tuned state, including mandatory `tuned-adm verify` (always enforced regardless of `INTERRUPT` variable)

## Configuration

### Environment Variables

#### INTERRUPT

The `INTERRUPT` environment variable controls how the package handles `tuned-adm verify` failures during different validation phases:

- **Purpose**: Determines whether to fail on `tuned-adm verify` errors in the config-check step
- **Values**:
  - `true`: Allow config-check to pass even if `tuned-adm verify` fails (recommended for tunings requiring an interrupt)
  - `false` or unset: Fail config-check if `tuned-adm verify` fails (default behavior)
- **When to use**: Set to `true` when applying tuning profiles that require an interrupt to take effect and verify correctly
- **Behavior**:
  - **config-check step**: If `INTERRUPT=true`, verification failures are logged as warnings but don't cause the step to fail
  - **post-interrupt-check step**: Always fails on verification errors regardless of INTERRUPT setting (tunings should be verifiable after an interrupt)

**Example configuration in SCR:**
```yaml
env:
    name: INTERRUPT
    value: true
```

### Configmaps

The package expects configmaps to be available in `${SKYHOOK_DIR}/configmaps/`:

#### Required Configmaps

- **`tuned_profile`**: Contains the name of the tuned profile(s) to apply. Supports multiple space-separated profiles for merged configurations.
  ```
  # Single profile example
  balanced
  
  # Multiple profiles example (settings from later profiles take precedence)
  throughput-performance network-latency
  ```

#### Optional Configmaps

- **Custom profile files**: Any files in the configmaps directory (except `tuned_profile` and `*_script` files) will be treated as custom tuned profile configurations
  - File name becomes the profile name
  - File contents become the `tuned.conf` for that profile
  - Files are deployed to `<profiles_dir>/<profile_name>/tuned.conf` (`<profiles_dir>` is `/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)

- **Script files**: Any files ending with `_script` will be deployed as executable scripts to `/etc/tuned/scripts/`
  - File name pattern: `<name>_script` (e.g., `setup_script`, `my_optimization_script`)
  - Scripts are deployed to `/etc/tuned/scripts/<name>` (the `_script` suffix is removed)
  - Scripts are automatically made executable (`chmod +x`)
  - Can be referenced in tuned profiles using the `[script]` plugin

### Example Custom Profile

```ini
# configmaps/my-custom-profile
[main]
summary=Custom performance profile for my application

[cpu]
governor=performance
energy_perf_bias=performance

[disk]
readahead=4096

[vm]
transparent_hugepages=never
```

### Example Custom Profile with Scripts

```ini
# configmaps/ai-optimized-profile
[main]
summary=AI/ML optimized profile with custom scripts

[cpu]
governor=performance
energy_perf_bias=performance

[script]
type=script
script=/etc/tuned/scripts/ai_setup

[vm]
transparent_hugepages=always
```

```bash
# configmaps/ai_setup_script
#!/bin/bash
# This script will be deployed to /etc/tuned/scripts/ai_setup

echo "Setting up AI/ML optimizations..."

# Configure GPU memory settings
if [ -d /sys/class/drm ]; then
    echo "Configuring GPU settings for AI workloads"
    # Add GPU-specific optimizations here
fi

# Set up NUMA topology optimizations
echo "Configuring NUMA settings for AI workloads"
for node in /sys/devices/system/node/node*; do
    if [ -d "$node" ]; then
        echo 0 > "$node/compact"
    fi
done

echo "AI optimization setup complete"
```

## Usage Examples

### Basic Installation
Deploy the package with apply mode to install tuned with default settings.

### Custom Profile Deployment
1. Create configmap files with your custom tuned profiles
2. Create a `tuned_profile` configmap specifying which profile to activate
3. Deploy the package with config mode to apply the custom configuration

### Complete NodeWright Configuration Example

Here's a complete example of using the tuned package with NodeWright to deploy custom AI/ML performance profiles:

```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  labels:
    app.kubernetes.io/part-of: skyhook-operator
    app.kubernetes.io/created-by: skyhook-operator
  name: skyhook-test
spec:
  nodeSelectors:
    matchLabels:
      eks.amazonaws.com/nodegroup: ml-nodes
  packages:
    tuned:
      image: nvcr.io/nvidian/swgpu-baseos/tuned
      version: 1.1.0
      interrupt:
        type: reboot
      configInterrupts:
        tuned_profile:
          type: reboot
        custom_profile:
          type: reboot
        custom_profile_1:
          type: reboot
      env:
        - name: INTERRUPT
          value: "true"
      configMap:
        tuned_profile: custom_profile
        custom_profile: |-
            [main]
            summary=AI/ML kernel settings
            include=custom_profile_1

            [sysctl]
            kernel.numa_balancing=1                  # avoid NUMA page bouncing
            kernel.panic=10

            [bootloader]
            cmdline_myprofile=-kernel.panic +kernel.panic=20
            
            [script]
            script=/etc/tuned/scripts/ai_init
        custom_profile_1: |-
            [main]
            summary=AI/ML performance profile

            [cpu]
            governor=performance             # lock CPUs at max frequency
            energy_perf_bias=performance     # disable energy saving bias
            force_latency=0                  # minimize C-state latency

            [disk]
            readahead=4096                   # bigger readahead for large dataset loads

            [vm]
            transparent_hugepages=always     # large pages help with tensor allocations
            swappiness=10                    # avoid swapping under load
        ai_init_script: |-
            #!/bin/bash
            # Custom AI/ML initialization script
            echo "Initializing AI/ML optimizations..."
            
            # Configure GPU memory pools
            if command -v nvidia-smi >/dev/null 2>&1; then
                echo "Configuring NVIDIA GPU settings"
                nvidia-smi -pm 1  # Enable persistence mode
            fi
            
            # Set up memory allocation patterns for AI workloads
            echo "Configuring memory allocation for AI workloads"
            echo 1 > /proc/sys/vm/overcommit_memory
            
            echo "AI initialization complete"
```

This example demonstrates:
- **Node targeting**: Using `nodeSelectors` to target specific node groups
- **Interrupt handling**: Configuring reboot interrupts for kernel-level changes
- **Environment variables**: Setting `INTERRUPT=true` to handle verification during config changes
- **Custom profiles**: Creating hierarchical profiles with `include` directive
- **Custom scripts**: Using `_script` configmaps to deploy executable scripts
- **Script integration**: Referencing deployed scripts in profiles using the `[script]` plugin
- **AI/ML optimizations**: Performance settings optimized for machine learning workloads
- **Kernel parameters**: Using `[sysctl]` and `[bootloader]` sections for low-level tuning

### Available Tuned Profiles

Common built-in profiles include:
- `balanced` - Default balanced profile
- `powersave` - Power saving profile
- `throughput-performance` - Maximum throughput
- `latency-performance` - Low latency optimization
- `network-latency` - Network latency optimization
- `network-throughput` - Network throughput optimization

Use `tuned-adm list` to see all available profiles on your system or go to [tuned profiles](https://github.com/redhat-performance/tuned/tree/master/profiles) to see the profiles which are automatically installed with tuned.

## Troubleshooting

### Common Issues

1. **Service fails to start**
   - Check system logs: `journalctl -u tuned`
   - Verify package installation: `rpm -q tuned` or `dpkg -l tuned`

2. **Profile not found**
   - List available profiles: `tuned-adm list`
   - Check custom profile deployment in the tuned profiles dir (`/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)

3. **Permission errors**
   - Ensure scripts run with appropriate privileges
   - Check tuned profiles dir permissions (`/etc/tuned/profiles` on tuned >= 2.23, else `/etc/tuned`)

4. **Verification errors**
   - Check verification: `tuned-adm verify`
   - Verify correct active profile: `tuned-adm active`
   - Check verification logs in `/var/log/tuned/tuned.log`
   - For tunings requiring reboot: Set `INTERRUPT=true` to allow config-check to pass despite verification failures

### Validation Commands

```bash
# Check tuned status
systemctl status tuned

# List available profiles
tuned-adm list

# Check active profile
tuned-adm active

# Verify profile recommendations
tuned-adm recommend

# Verify tuning has finished
tuned-adm verify
```

## Dependencies

- **System Requirements**: Linux with systemd
- **Package Managers**: apt, yum, or dnf
- **Runtime Dependencies**:
  - `systemctl` (systemd)
  - `sudo` (for profile management)

## Version

- **Package Version**: 1.0.0
- **Schema Version**: v1

## Contributing

When modifying this package:

1. Ensure all scripts maintain idempotency
2. Add appropriate error handling and validation
3. Update both action and check scripts for new functionality
4. Test across all supported distributions
5. Update this README with any new features or requirements
