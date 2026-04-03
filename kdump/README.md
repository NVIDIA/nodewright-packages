# Kdump Package

This NodeWright Package provides automated installation and configuration of kdump for crash dump collection on Linux systems. It supports multiple distributions and handles the complete lifecycle from installation to post-interrupt validations.

## Overview

The kdump package configures kernel crash dump functionality, which captures the contents of system memory when a kernel panic occurs. This is essential for debugging kernel crashes and system failures in production environments.

**Capabilities:**
- Multi-distribution support (Ubuntu/Debian, CentOS/RHEL/Amazon Linux/Fedora)
- Automated kdump package installation
- Crashkernel parameter configuration in GRUB
- Kdump service configuration and management
- Comprehensive validation and health checks
- Safe uninstallation with cleanup

## Required ConfigMaps

### `crashkernel`
Specifies the amount of memory to reserve for the crash kernel. This value is added to the kernel command line.

**Format:** Single line with the crashkernel value
**Examples:**
- `256M` - Reserve 256MB for crash kernel
- `512M` - Reserve 512MB for crash kernel
- `1G` - Reserve 1GB for crash kernel
- `auto` - Let the system determine the appropriate size

Read the kdump documentation for more information for correct crashkernel sizes.

### `kdump.conf` (Optional)
Custom kdump configuration file content. If not provided, the package uses system defaults.

**Format:** Standard kdump.conf format
**Example:**
```
path /var/crash
core_collector makedumpfile -l --message-level 1 -d 31
```

## Lifecycle Stages

### Apply Stage (`install_kdump.sh`)
- Detects the Linux distribution
- Installs appropriate kdump packages:
  - **Ubuntu/Debian**: `kdump-tools`, `crash`, `makedumpfile`
  - **CentOS/RHEL/Amazon/Fedora**: `kexec-tools`, `crash`
- Enables kdump service for automatic startup

### Config Stage (`configure_kdump.sh`)
- Reads crashkernel value from configmap
- Configures GRUB with crashkernel parameter:
  - Uses `/etc/default/grub.d/` if available (preferred)
  - Falls back to modifying `/etc/default/grub` directly
- Updates GRUB configuration (`update-grub` or `grub2-mkconfig`)
- Copies custom kdump.conf if provided

### Post-Interrupt Check (`kdump_post_interrupt_check.sh`)
- Validates crashkernel parameter is active in running kernel
- Verifies kdump service is running and enabled
- Performs comprehensive system state validation

### Uninstall Stage (`uninstall_kdump.sh`)
- Removes crashkernel parameter from GRUB configuration
- Updates GRUB to remove crash kernel reservation
- Stops and disables kdump service
- Removes installed kdump packages
- Cleans up configuration files

**NOTE**: The crashkernel will be removed from the GRUB config, but a reboot will be needed in order for that to take effect. This isn't handled by the kdump NodeWright package.

## Example NodeWright Custom Resource

### Basic kdump setup with 256MB crash kernel:
```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: kdump-setup
spec:
  nodeSelectors:
    matchLabels:
      skyhook.nvidia.com/node-type: worker
  packages:
    kdump:
      version: 1.1.0
      image: ghcr.io/nvidia/skyhook-packages/kdump:1.1.0
      interrupt:
        type: reboot  # required for crashkernel parameter to take effect
      configInterrupts:
        crashkernel:
          type: reboot
      configMap:
        crashkernel: "256M"
```

### Advanced setup with custom kdump configuration:
```yaml
apiVersion: skyhook.nvidia.com/v1alpha1
kind: Skyhook
metadata:
  name: kdump-advanced
spec:
  nodeSelectors:
    matchLabels:
      skyhook.nvidia.com/node-type: worker
  packages:
    kdump:
      version: 1.1.0
      image: ghcr.io/nvidia/skyhook-packages/kdump:1.1.0
      interrupt:
        type: reboot # required for crashkernel parameter to take effect
      configInterrupts:
        crashkernel:
          type: reboot
        kdump.conf:
          type: service
          services: ["kdump"] # For RHEL/CentOS/Fedora
          services: ["kdump-tools"] # For Debian based distros
      configMap:
        crashkernel: "512M"
        kdump.conf: |
          # kdump-tools configuration
          # ---------------------------------------------------------------------------
          # USE_KDUMP - controls kdump will be configured
          #     0 - kdump kernel will not be loaded
          #     1 - kdump kernel will be loaded and kdump is configured
          #
          USE_KDUMP=1


          # ---------------------------------------------------------------------------
          # Kdump Kernel:
          # KDUMP_KERNEL - A full pathname to a kdump kernel.
          # KDUMP_INITRD - A full pathname to the kdump initrd (if used).
          #     If these are not set, kdump-config will try to use the current kernel
          #     and initrd if it is relocatable.  Otherwise, you will need to specify
          #     these manually.
          KDUMP_KERNEL=/var/lib/kdump/vmlinuz
          KDUMP_INITRD=/var/lib/kdump/initrd.img


          # ---------------------------------------------------------------------------
          # vmcore Handling:
          # KDUMP_COREDIR - local path to save the vmcore to.
          # KDUMP_FAIL_CMD - This variable can be used to cause a reboot or
          #     start a shell if saving the vmcore fails.  If not set, "reboot -f"
          #     is the default.
          #     Example - start a shell if the vmcore copy fails:
          #         KDUMP_FAIL_CMD="echo 'makedumpfile FAILED.'; /bin/bash; reboot -f"
          # KDUMP_DUMP_DMESG - This variable controls if the dmesg buffer is dumped.
          #     If unset or set to 1, the dmesg buffer is dumped. If set to 0, the dmesg
          #     buffer is not dumped.
          # KDUMP_NUM_DUMPS - This variable controls how many dump files are kept on
          #     the machine to prevent running out of disk space. If set to 0 or unset,
          #     the variable is ignored and no dump files are automatically purged.
          # KDUMP_COMPRESSION - Compress the dumpfile. No compression is used by default.
          #     Supported compressions: bzip2, gzip, lz4, xz
          KDUMP_COREDIR="/var/crash"
          #KDUMP_FAIL_CMD="reboot -f"
          #KDUMP_DUMP_DMESG=
          #KDUMP_NUM_DUMPS=
          #KDUMP_COMPRESSION=


          # ---------------------------------------------------------------------------
          # Makedumpfile options:
          # MAKEDUMP_ARGS - extra arguments passed to makedumpfile (8).  The default,
          #     if unset, is to pass '-c -d 31' telling makedumpfile to use compression
          #     and reduce the corefile to in-use kernel pages only.
          #MAKEDUMP_ARGS="-c -d 31"


          # ---------------------------------------------------------------------------
          # Kexec/Kdump args
          # KDUMP_KEXEC_ARGS - Additional arguments to the kexec command used to load
          #     the kdump kernel
          #     Example - Use this option on x86 systems with PAE and more than
          #     4 gig of memory:
          #         KDUMP_KEXEC_ARGS="--elf64-core-headers"
          # KDUMP_CMDLINE - The default is to use the contents of /proc/cmdline.
          #     Set this variable to override /proc/cmdline.
          # KDUMP_CMDLINE_APPEND - Additional arguments to append to the command line
          #     for the kdump kernel.  If unset, it defaults to
          #     "reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 irqpoll nousb"
          #KDUMP_KEXEC_ARGS=""
          #KDUMP_CMDLINE=""
          #KDUMP_CMDLINE_APPEND="reset_devices systemd.unit=kdump-tools-dump.service nr_cpus=1 irqpoll nousb"


          # ---------------------------------------------------------------------------
          # Architecture specific Overrides:

          # ---------------------------------------------------------------------------
          # Remote dump facilities:
          # HOSTTAG - Select if hostname of IP address will be used as a prefix to the
          #           timestamped directory when sending files to the remote server.
          #           'ip' is the default.
          #HOSTTAG="hostname|[ip]"

          # NFS -     Hostname and mount point of the NFS server configured to receive
          #           the crash dump. The syntax must be {HOSTNAME}:{MOUNTPOINT}
          #           (e.g. remote:/var/crash)
          # NFS_TIMEO - Timeout before NFS retries a request. See man nfs(5) for details.
          # NFS_RETRANS - Number of times NFS client retries a request. See man nfs(5) for details.
          #NFS="<nfs mount>"
          #NFS_TIMEO="600"
          #NFS_RETRANS="3"

          # FTP - Hostname and path of the FTP server configured to receive the crash dump.
          #       The syntax is {HOSTNAME}[:{PATH}] with PATH defaulting to /.
          # FTP_USER - FTP username. A anonomous upload will be used if not set.
          # FTP_PASSWORD - password for the FTP user
          # FTP_PORT=21 - FTP port. Port 21 will be used by default.
          #FTP="<server>:<path>"
          #FTP_USER=""
          #FTP_PASSWORD=""
          #FTP_PORT=21

          # SSH - username and hostname of the remote server that will receive the dump
          #       and dmesg files.
          # SSH_KEY - Full path of the ssh private key to be used to login to the remote
          #           server. use kdump-config propagate to send the public key to the
          #           remote server
          #SSH="<user at server>"
          #SSH_KEY="<path>"
```

## Important Notes

### Single Package Support
**Note:** Only one kdump package should be enabled at any given time. Configuring multiple kdump packages simultaneously can lead to conflicts and unpredictable behavior.

### Reboot Requirement
- **Initial Setup**: A reboot is required after applying the package for the crashkernel parameter to take effect
- **Configuration Changes**: Changing the crashkernel value requires a reboot
- **Service Changes**: Modifying kdump.conf may require service restart but not a full reboot
- **Uninstallation**: The crashkernel will be removed from the GRUB config after an uninstallation, but a reboot will be needed in order for that to take effect. This isn't handled by the kdump NodeWright package.

### Memory Considerations
- The crashkernel parameter reserves memory that is not available to the main system
- Choose an appropriate size based on your system's total memory and debugging needs
- Too small: May not capture complete crash dumps
- Too large: Reduces available system memory

### Distribution Support
The package automatically detects and supports:
- **Ubuntu 18.04+** and **Debian 9+**
- **CentOS 7+**, **RHEL 7+**, **Amazon Linux 2+**
- **Fedora 30+**

### Validation
The package includes comprehensive checks:
- GRUB configuration validation
- Kernel parameter verification
- Service status monitoring
- Cross-stage consistency validation

## Troubleshooting

### Common Issues

1. **Crashkernel not active after reboot**
   - Verify GRUB configuration was updated correctly
   - Check if secure boot is preventing kernel parameter changes
   - Ensure sufficient memory is available for reservation

2. **Kdump service fails to start**
   - Check system logs: `journalctl -u kdump` (kdump-tools on debian-based distros)
   - Verify crashkernel parameter is active: `cat /proc/cmdline`
   - Ensure adequate memory is reserved

3. **Package installation fails**
   - Verify network connectivity for package downloads
   - Check distribution compatibility
   - Review package manager logs

### Verification Commands

```bash
# Check if crashkernel is active
cat /proc/cmdline | grep crashkernel

# Verify kdump service status
systemctl status kdump (kdump-tools on debian-based distros)

# Check available crash dump space
df -h /var/crash

# Test crash dump functionality (USE WITH CAUTION)
echo c > /proc/sysrq-trigger
```

## Security Considerations

- Crash dumps may contain sensitive information from system memory
- Ensure proper access controls on crash dump storage locations
- Consider encryption for crash dump files in sensitive environments
- Regular cleanup of old crash dumps to prevent disk space issues

## Kdump Documentation:
- [official kernel documentation](https://docs.kernel.org/admin-guide/kdump/kdump.html)
- [redhat kdump documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/kernel_administration_guide/kernel_crash_dump_guide)
