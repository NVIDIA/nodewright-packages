

# Changelog

Each NodeWright package is versioned and released independently.
Full changelogs are maintained per package and published as [GitHub Releases](https://github.com/NVIDIA/nodewright-packages/releases).

## Packages

| Package | Changelog |
|---|---|
| shellscript | [shellscript/CHANGELOG.md](shellscript/CHANGELOG.md) |
| tuning | [tuning/CHANGELOG.md](tuning/CHANGELOG.md) |
| tuned | [tuned/CHANGELOG.md](tuned/CHANGELOG.md) |
| kdump | [kdump/CHANGELOG.md](kdump/CHANGELOG.md) |
| nvidia-setup | [nvidia-setup/CHANGELOG.md](nvidia-setup/CHANGELOG.md) |
| nvidia-tuned | [nvidia-tuned/CHANGELOG.md](nvidia-tuned/CHANGELOG.md) |
| nvidia-tuning-gke | [nvidia-tuning-gke/CHANGELOG.md](nvidia-tuning-gke/CHANGELOG.md) |

## Generating

Regenerate a package changelog from git history:

```bash
make changelog PACKAGE=nvidia-setup
```

Preview unreleased changes before tagging:

```bash
make changelog-preview PACKAGE=nvidia-setup
```
