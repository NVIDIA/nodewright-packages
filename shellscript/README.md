This NodeWright Package allows you to run arbitrary bash scripts defined in your NodeWright Custom Resource.

# Example package configuration

```yaml
example:
    version: 1.1.2
    image: ghcr.io/nvidia/nodewright-packages/shellscript
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

## Package artifact

From its next release, `shellscript` is also published as a NodeWright package artifact, an OCI artifact the operator inspects and the agent lays out itself, with no package image to run and no init copy. It holds the same files as the image of the same version, and its metadata is this package's `config.json`, which declares uninstall supported because the package has `uninstall` and `uninstall-check` modes.

The artifact lives next to the image under its own name, because an image and an artifact cannot share a tag:

```text
ghcr.io/nvidia/nodewright-packages/shellscript-artifact:<version>
```

A NodeWright uses it with the same `image` and `version` fields, pointed at the artifact:

```yaml
example:
    version: <version>
    image: ghcr.io/nvidia/nodewright-packages/shellscript-artifact
    configMap:
        apply.sh: |-
            #!/bin/bash
            echo "hello world" > /skyhook-hello-world
```

This needs package-artifact support from [NVIDIA/nodewright#875](https://github.com/NVIDIA/nodewright/pull/875), which is not released yet. Two requirements follow from it:

- **Operator:** the first operator release after `operator/v0.20.0`, or later, with `packageArtifacts` enabled in the chart (`controllerManager.manager.env.packageArtifacts: "true"`).
- **Agent:** while that option is on, every agent the operator runs must be the first agent release after `agent/v7.0.0`, or later.

With the option off, keep using the image.

The artifact is signed and carries SLSA provenance, like the image; verify it with [Verifying Release Artifacts](../SECURITY.md#verifying-release-artifacts), using the `shellscript-artifact` repository.
