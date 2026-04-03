This NodeWright Package allows you to run arbitrary bash scripts defined in your NodeWright Custom Resource.

# Example package configuration
```
example:
    version: 1.1.1
    image: ghcr.io/nvidia/skyhook-packages/shellscript
    configMap:
    apply.sh: |-
        #!/bin/bash
        echo "hello world" > /skyhook-hello-world
        sleep 60
    apply_check.sh: |-
        #!/bin/bash
        cat /skyhook-hello-world
        sleep 30
    config.sh: |-
        #!/bin/bash
        echo "a config is run" >> /skyhook-hello-world
        sleep 60
    config_check.sh: |-
        #!/bin/bash
        grep "config" /skyhook-hello-world
        sleep 30
```