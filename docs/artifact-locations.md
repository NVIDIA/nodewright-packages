# Package Image Locations

Package images have been published under two GitHub Container Registry paths, because the repository was renamed from `NVIDIA/skyhook-packages` to `NVIDIA/nodewright-packages` and the image path follows the repository name. This page lists where every released version of every package lives, so you can find an older version, tell where an image you are running came from, or update a pinned reference.

Each released version exists in exactly one place: nothing was copied between the two paths. The old path is **frozen, not deleted**: it still serves the versions it holds, but receives nothing new.

## Where to get packages today

```text
ghcr.io/nvidia/nodewright-packages/<package>:<version>
```

Release tags `<package>/<version>` publish here through `build_container.yaml`. Stable releases also move `latest`; release candidates (`<version>-rc.N`) do not. See [Verifying Release Artifacts](../SECURITY.md#verifying-release-artifacts) to check an image's signature and provenance before you run it.

Releases are also staged to NGC at `nvcr.io/1070195845945670/nodewright-packages/<package>`, from where NVIDIA's internal release process promotes them to the public `nvcr.io/nvidia` catalog. Only the version tag is staged; `latest` is a GHCR tag. The staging location is not meant to be pulled from directly. This repository's workflows have never published package images to a public NGC path.

### Package artifacts

Every package is also published as a NodeWright package artifact, built from the image of the same version, except one whose `/skyhook-package` differs between amd64 and arm64 (today `kata-containers`), which a single artifact cannot represent:

```text
ghcr.io/nvidia/nodewright-packages/<package>-artifact:<version>
```

The artifact gets its own repository because an image and an artifact cannot share a tag, and a `-artifact` suffix rather than a nested path because NGC names are `<org>/<team>/<name>`: it is staged as `nvcr.io/1070195845945670/nodewright-packages/<package>-artifact`. Only version tags are published; the artifact never has a `latest`. Its metadata is the package's own `config.json`, with uninstall supported when that config has an `uninstall` mode. It is signed and carries SLSA provenance like the image. Pull request builds push `<version>-dev.sha<short>` artifacts the same way, unsigned.

## Versions by location

| Package | `ghcr.io/nvidia/skyhook-packages` (frozen) | `ghcr.io/nvidia/nodewright-packages` (current) |
| --- | --- | --- |
| `shellscript` | 1.0.0, 1.1.0, 1.1.1 | 1.1.2 onward |
| `tuning` | 1.0.0, 1.1.0 to 1.1.4 | 1.1.5 onward |
| `tuned` | 1.0.0, 1.1.0, 1.2.0 | 1.3.0 onward |
| `kdump` | 1.0.0, 1.1.0 | 1.1.1 onward |
| `nvidia-setup` | 0.1.0 to 0.2.1 | 0.2.2 onward |
| `nvidia-tuned` | 0.1.0 to 0.2.3 | 0.3.0 onward |
| `nvidia-tuning-gke` | 0.1.0, 0.1.1 | 0.1.2 onward |
| `bind-mount` | none | 0.1.0 onward |
| `copy-fail` | none | 1.0.0 onward |

`latest` on the frozen path still points at the last version published there, so an image pinned to `skyhook-packages/<package>:latest` is not receiving updates.

Two release tags have no image anywhere: `shellscript/1.0.1` and `nvidia-tuned/0.2.4` (whose build failed).

## Verifying an older image

The signer identity in a keyless signature names the repository that built the image, so it differs between the two paths:

| Path | Certificate identity |
| --- | --- |
| `ghcr.io/nvidia/skyhook-packages/<package>` | `https://github.com/NVIDIA/skyhook-packages/.github/workflows/build_container.yaml@refs/tags/<package>/<version>` |
| `ghcr.io/nvidia/nodewright-packages/<package>` | `https://github.com/NVIDIA/nodewright-packages/.github/workflows/build_container.yaml@refs/tags/<package>/<version>` |

Use the recipe in [Verifying Release Artifacts](../SECURITY.md#verifying-release-artifacts) with the path and identity from the matching row.

## Inherited packages

A package that inherits from another (`FROM` another package image in its `Dockerfile`) pulls its base from whichever path its `Dockerfile` names at that version:

- `nvidia-tuned` built from `skyhook-packages/tuned` up to 0.3.0, and from `nodewright-packages/tuned` from 0.3.1.
- `nvidia-tuning-gke` switched to `nodewright-packages` at 0.1.2.

New packages should inherit from `ghcr.io/nvidia/nodewright-packages/...`; the validation tooling accepts both names so that older versions still build.

## Development builds

Pull request builds push `<version>-dev.sha<short>` tags to the same repository as releases (older ones used `<version>-dev.<sha>` or `0.0.0-<sha>`). They are for testing a change before release, never move `latest`, and should not be pinned in production.

## Examples elsewhere in this repository

Some package READMEs still show `ghcr.io/nvidia/skyhook-packages/...` in their examples. Those versions exist and still pull, but they are old; take the current version from the table above or from the [releases page](https://github.com/NVIDIA/nodewright-packages/releases).
