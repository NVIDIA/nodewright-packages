Use configmaps to set:
 * service settings
    * Requires a restart_all_services interrupt
    * Or a restart of the service changed
 * ulimit settings
    * No interrupt required
 * container limit settings (ulimits as seen by containers)
    * requires a reboot interrupt
 * grub configuration
    * requires a reboot interrupt

All changes are made via a drop-in file so they can be uninstalled later without conflicts with other things that might alter the same setting.

# Supported configmaps
* `grub.conf` - This will be used to set grub. The format is one line per argumennt which are turned into space separated values for `GRUB_CMDLINE_LINUX_DEFAULT`. Suggested to use a reboot so changes are applied
* `sysctl.conf` - This will be set into `/etc/systctl.d`. Suggested to use a reboot or restart_all_services to ensure changes are picked up
* `ulimit.conf` - This set a drop in file in /etc/security/limits.d. It also can call ulimit directly for the following values:
    * memlock
    * nofile
    * fsize
    * stack
    * nproc
* `service_{service name}.conf` - This will make a drop-in file in `/etc/systemd/system/{service name}.service.d`. Suggested to use a service restart for this service. `systemctl daemon-reload` is called for you if any are set.

## Special service config files
If you use `service_containerd.conf` or `service_crio.conf` post-interrupt check will do a further validation on the settings. If the following lines are in your configmap:
 * LimitNOFILE
 * LimitFSIZE
 * LimitSTACK
 * LimitNPROC
 * LimitMEMLOCK
It will use ulimit to check that the expected value is actually set. Note: for `LimitSTACK` and `LimitMEMLOCK` it compares against expected_value/1024 due to formatting output of the ulimit call.


# Example NodeWright Custom Resource
Update grub and sysctl. 
Use main reboot interrupt for the first apply.
Specify different interrupts for the configmap interrupts to apply a more limited one depending on which one changes.
```yaml
tuning:
    version: 1.1.4
    image: ghcr.io/nvidia/skyhook-packages/tuning
    interrupt:
        type: reboot
    configInterrupts:
        grub.conf:
            type: reboot
        sysctl.conf:
            type: restart_all_services
    configMap:
        grub.conf: |-
            hugepagesz=1G
            hugepages=2
            hugepagesz=2M
            hugepages=5128
        sysctl.conf: |-
            fs.inotify.max_user_instances=65535
            fs.inotify.max_user_watches=524288
            kernel.threads-max=16512444
            vm.max_map_count=262144
            vm.min_free_kbytes=65536
        ulimit.conf: |-
            memlock=128
            fsize=1000
```

Update just sysctl
```yaml
tuning:
    version: 1.1.4
    image: ghcr.io/nvidia/skyhook-packages/tuning
    interrupt:
        type: restart_all_services
    configMap:
        sysctl.conf: |-
            fs.inotify.max_user_instances=65535
            fs.inotify.max_user_watches=524288
            kernel.threads-max=16512444
            vm.max_map_count=262144
            vm.min_free_kbytes=65536
```

Update containerd stack size
```yaml
tuning:
    version: 1.1.4
    image: ghcr.io/nvidia/skyhook-packages/tuning
    interrupt:
        type: service
        services:
            - containerd
    configMap:
        service_containerd.conf: |-
            [Service]
            LimitSTACK=67108864
            LimitMEMLOCK=infinity
```

