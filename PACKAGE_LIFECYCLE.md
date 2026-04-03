# Package Lifecycle Documentation

This document describes the lifecycle stages of NodeWright packages and how they are executed by the [NodeWright Operator](https://github.com/NVIDIA/skyhook).

## Overview

NodeWright packages follow a well-defined lifecycle with multiple stages that ensure proper installation, configuration, and management of node-level changes. Each stage serves a specific purpose and is executed at the appropriate time based on package state changes.

## Lifecycle Stages

### 1. Apply Stage
- **Purpose**: Initial installation and setup of the package.
- **When executed**: Always runs at least once when a package is first applied
- **Modes**: `apply`, `apply-check`
- **Example use cases**:
  - Install software components
  - Create configuration files
  - Set up required directories
  - Initialize services

### 2. Config Stage
- **Purpose**: Handle configuration changes and updates
- **When executed**: When a configmap is changed and on the first SCR application
- **Modes**: `config`, `config-check`
- **Example use cases**:
  - Update configuration files
  - Apply new settings
  - Modify service parameters
  - Update environment variables

### 3. Interrupt Stage
- **Purpose**: Handle interruptions like service restarts or reboots
- **When executed**: When a package has an interrupt defined or a configmap key changes that has a config interrupt defined
- **Types**: `service`, `reboot`, `restart_all_services`
- **Example use cases**:
  - Restart specific services
  - Reboot the node
  - Signal running processes

### 4. Post-Interrupt Stage
- **Purpose**: Perform validation and cleanup after interrupts
- **When executed**: After a package's interrupt has finished
- **Modes**: `post-interrupt`, `post-interrupt-check`
- **Example use cases**:
  - Apply additional modifications that are required post interrupt
  - Verify services are running correctly
  - Validate configuration changes took effect

### 5. Upgrade Stage
- **Purpose**: Handle package version upgrades
- **When executed**: When a package's version is upgraded in the SCR
- **Modes**: `upgrade`, `upgrade-check`
- **Example use cases**:
  - Migrate data formats
  - Update existing configurations
  - Handle compatibility changes
  - Preserve user settings

### 6. Uninstall Stage
- **Purpose**: Clean removal of package components
- **When executed**: When a package's version is downgraded or removed from the SCR
- **Modes**: `uninstall`, `uninstall-check`
- **Example use cases**:
  - Remove installed files
  - Stop and disable services
  - Clean up configuration files
  - Restore system state

## Execution Order

The lifecycle stages are executed in a specific order to ensure proper package management:

### Normal Flow (No Upgrade)
```
Uninstall → Apply → Config → Interrupt → Post-Interrupt
```

### Upgrade Flow
```
Upgrade → Config → Interrupt → Post-Interrupt
```

> **Note**: Semantic versioning is strictly enforced to determine whether an upgrade or uninstall should occur.

## Implementation Guidelines

### Check Modes
Each stage should implement both an action mode and a check mode:
- **Action mode**: Performs the actual operation
- **Check mode**: Validates that the operation was successful

### Idempotence
All stages should be idempotent, meaning they can be run multiple times safely without causing issues. This can be done using the agents auto idempotence, which writes out a file to track. Or insure the scripts can be run over and over without side effect.

## Best Practices

### 1. Use ConfigMaps for Dynamic Configuration
- Store configuration in configMaps for easy updates
- Use config interrupts to apply changes immediately
- Validate configuration before applying

### 2. Handle Interrupts Appropriately
- Choose the right interrupt type (service, reboot, restart_all_services)
- Minimize disruption by using targeted interrupts
- Implement proper post-interrupt validation

### 3. Implement Robust Check Modes
- Verify all changes were applied successfully
- Check service status and health
- Validate file permissions and ownership
- Test functionality end-to-end

### 4. Plan for Rollbacks
- Implement proper uninstall procedures
- Backup original configurations
- Test downgrade scenarios
- Handle data migration carefully

### 5. Use Semantic Versioning
- Follow semver strictly for proper upgrade/downgrade detection
- Tag releases appropriately
- Document breaking changes

## Package-Specific Examples

### Shellscript Package
Supports all lifecycle stages and can run arbitrary bash scripts defined in configMaps.

**Supported stages**: apply, config, post-interrupt, uninstall (with checks)

### Tuning Package
Focuses on system configuration and tuning parameters.

**Supported stages**: config, post-interrupt, uninstall (with checks)
**Special features**: 
- Validates container runtime settings
- Handles grub, sysctl, ulimit, and systemd configurations
- Supports different interrupt types for different configuration changes

## Troubleshooting

### Common Issues
1. **Check mode failures**: Ensure check logic properly validates the expected state
2. **Interrupt timeouts**: Verify services restart properly and within expected timeframes
3. **Idempotence issues**: Test that scripts can run multiple times safely, or use default auto idempotence.
4. **Configuration conflicts**: Handle cases where multiple packages modify the same settings. Using drop in files for config make it easy to avoid this, and also handle uninstall.

All package `config.json` files must comply with the official JSON schemas defined in the [NVIDIA NodeWright Agent Schemas](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1). The skyhook-agent includes a built-in validation tool that should be used to test packages before publishing.

### Validating Your Package

Before deploying packages, ensure your `config.json` validates against the schema:

```bash
# The skyhook-agent includes validation tooling
# Use this to validate your package configuration
skyhook-agent validate /path/to/your/config.json
```

## References

- [NVIDIA NodeWright Documentation](https://github.com/NVIDIA/skyhook)
- [NodeWright Agent Schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1)
- [NodeWright Stages Documentation](https://github.com/NVIDIA/skyhook/blob/main/README.md#stages)
- [Kubernetes Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) 