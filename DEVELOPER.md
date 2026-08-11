# Developer Guide

This guide provides information for developers working on NodeWright packages, including validation steps to run before committing changes.

## Pre-Commit Validations

Before committing your changes, you should run the following validations to ensure your code meets the repository standards:

### 1. License Header Formatting

Source files (`*.py`, `*.sh`, `*.yaml`/`*.yml`, and `Dockerfile`s) must carry the full
Apache 2.0 license header (see `.github/license-header.tmpl`). Markdown and other docs
do not need a header. Add or refresh headers with:

```bash
make license-fmt
```

This runs [`google/addlicense`](https://github.com/google/addlicense) via `go run`
(needs a local Go toolchain); it is idempotent and never duplicates a header. Verify
headers without modifying files (this is what CI runs) using:

```bash
make license-check
```

The `License Headers` workflow gates this on every PR, and also fails if a file ends up
with a duplicated header.

### 2. Config.json Validation

All packages must have a valid `config.json` file that complies with the [skyhook agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1).

**Important:** 
- Standalone packages (those not inheriting from another skyhook-packages image) **must** have a `config.json` file
- Packages that inherit from another skyhook-packages image (e.g., `nvidia-tuned` inherits from `tuned`) can omit `config.json` if they don't need their own configuration

#### Running Config Validation

To validate `config.json` files locally, use the published skyhook-agent image from [ghcr.io](https://ghcr.io/nvidia/skyhook/agent). The skyhook-agent source code is available in the [NVIDIA/skyhook repository](https://github.com/NVIDIA/skyhook).

**Prerequisites:**
- Docker installed and running

**Quick Start - Using Makefile:**

The easiest way to validate packages is using the makefile targets:

```bash
# For standalone packages (not inherited)
make validate-standalone PACKAGE=<package-name>

# For inherited packages (inherits from skyhook-packages)
make validate-inherited PACKAGE=<package-name>
```

**Examples:**
```bash
# Validate a standalone package
make validate-standalone PACKAGE=shellscript

# Validate an inherited package
make validate-inherited PACKAGE=nvidia-tuned
```

**Manual Validation:**

**Important for Inherited Packages:**

If your package inherits from another skyhook-packages image (i.e., your Dockerfile has `FROM ghcr.io/nvidia/skyhook-packages/...`), you **must build the container first** before validating. This is because the validation needs access to all files that will be in the final container, including those from the base image.

**For inherited packages, build first:**
```bash
# Build your package container
docker build -t my-package:test <package-name>

# Extract /skyhook-package from the built container
docker create --name temp-extract my-package:test
docker cp temp-extract:/skyhook-package /tmp/extracted-package
docker rm temp-extract

# Validate using the extracted package
docker run --rm \
  --entrypoint python \
  -v /tmp/extracted-package:/skyhook-package:ro \
  -v $(pwd)/scripts/validate.py:/tmp/validate.py:ro \
  ghcr.io/nvidia/skyhook/agent:latest \
  /tmp/validate.py /skyhook-package/config.json

# Cleanup
rm -rf /tmp/extracted-package
```

**For standalone packages (not inherited), validate directly:**

**Validate a single config.json file:**

```bash
docker run --rm \
  --entrypoint python \
  -v $(pwd):/workspace \
  -w /workspace \
  ghcr.io/nvidia/skyhook/agent:latest \
  /workspace/scripts/validate.py /workspace/<package-name>/config.json
```

**Example - Validate shellscript package:**

```bash
docker run --rm \
  --entrypoint python \
  -v $(pwd):/workspace \
  -w /workspace \
  ghcr.io/nvidia/skyhook/agent:latest \
  /workspace/scripts/validate.py /workspace/shellscript/config.json
```

**Validate all config.json files in the repository:**

```bash
# Find all config.json files and validate each
for config in */config.json; do
  echo "Validating $config..."
  docker run --rm \
    --entrypoint python \
    -v $(pwd):/workspace \
    -w /workspace \
    ghcr.io/nvidia/skyhook/agent:latest \
    /workspace/scripts/validate.py "/workspace/$config" || exit 1
done
```

### 3. Commit Message Format

All commits must use [Conventional Commits](https://www.conventionalcommits.org/) format with the package name as scope:

- `feat(shellscript): Add support for upgrade stage`
- `fix(tuning): Post-interrupt check for containerd changes did not allow infinity setting`
- `docs(general/ci): Update the main README.md for CI workflow`

### 4. Sign-off

All commits must be signed off. Use `git commit -s` to automatically add your sign-off, or manually add:

```
Signed-off-by: Your Name <your.email@example.com>
```

## Running Tests

The suite is Docker-based: each test copies a package into a temporary
directory, bind-mounts it into a throwaway container, and runs a lifecycle
script inside it. A working Docker (or Podman) daemon is required. Both targets
create a `venv/` on first run.

```bash
# Every package, in parallel
make test

# A single package (test dirs use underscores: nvidia-setup -> nvidia_setup)
make test-package PACKAGE=nvidia-setup
```

`tests/helpers/` holds the shared harness plus its own tests. Run those directly
when you change the harness itself:

```bash
./venv/bin/pytest tests/helpers/ -v
```

### Running tests on macOS

The harness bind-mounts a temporary directory into each container, and Docker
Desktop and colima share only certain host paths with the daemon's VM. The
default macOS `TMPDIR` (`/var/folders/...`) is usually not one of them. When it
is not shared, the mount silently comes up empty and every test fails with
`Script ... not found in container`, which does not point at the real cause.
Point `TMPDIR` at a shared path first:

```bash
export TMPDIR="$HOME/.cache/skyhook-tests"
mkdir -p "$TMPDIR"
make test
```

## CI Validation

The CI pipeline automatically runs validations:

- **PR Builds**: Validates `config.json` files that were changed in the PR
- **Tag Builds**: Always validates `config.json` files before building containers
- **Inherited Packages**: For packages that inherit from other skyhook-packages images, the container is built first, then validation runs against the built container to ensure all files (including those from the base image) are available
- **Build Blocking**: If validation fails, the container build is blocked

## Package Structure Requirements

### Required Files

- **`Dockerfile`**: Required for all packages
- **`config.json`**: Required unless the package inherits from another skyhook-packages image
- **`README.md`**: Recommended for documentation

### Config.json Requirements

- Must comply with [skyhook agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1)
- Must include valid `schema_version`, `package_name`, and `package_version`
- `package_version` must follow [Semantic Versioning](https://semver.org/)

### Dockerfile Requirements

- If your package inherits from another skyhook-packages image, the `FROM` line must contain `skyhook-packages` in the image path
- Example: `FROM ghcr.io/nvidia/skyhook-packages/tuned:${TUNED_VERSION}`

## Troubleshooting

### Validation Fails with "Failed to import skyhook_agent.config"

This error indicates the script is not running in the skyhook-agent container. Make sure you're using `docker run` with the skyhook-agent image.

### Validation Fails with "Step files did not exist" for Inherited Packages

If your package inherits from another skyhook-packages image and validation fails with "Step files did not exist", you need to build the container first before validating. The validation script needs access to all files that will be in the final container, including those from the base image. See the "Important for Inherited Packages" section above for instructions.

### Validation Fails with "Config file not found"

Check that:
1. The path to `config.json` is correct
2. The file exists in the package directory
3. The volume mount path is correct (should be `/workspace/<package-name>/config.json`)

### Build Fails with "config.json is required"

This means:
1. Your package doesn't have a `config.json` file, AND
2. Your Dockerfile doesn't inherit from another skyhook-packages image

Either:
- Add a `config.json` file to your package, OR
- Update your Dockerfile to inherit from a skyhook-packages image (e.g., `FROM ghcr.io/nvidia/skyhook-packages/<package-name>:<version>`)

## Additional Resources

- [Package Lifecycle Documentation](./PACKAGE_LIFECYCLE.md) - Comprehensive guide to package lifecycle stages
- [Contributing Guide](./CONTRIBUTING.md) - General contribution guidelines
- [Main README](./README.md) - Repository overview and package documentation
- [NodeWright Agent Schemas](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1) - Official schema documentation
