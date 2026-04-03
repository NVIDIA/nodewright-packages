# NodeWright Packages Testing Framework

This directory contains the testing framework for NodeWright packages. All tests run in isolated Docker containers to protect the development OS.

## Overview

The testing framework uses Python with pytest for test orchestration and the Docker Python SDK for container management. Tests execute NodeWright package scripts directly in isolated Ubuntu containers, allowing real system commands to run safely without modifying the host system.

## Package Structure Understanding

When packages are built, the **package root** (everything in the package directory) gets copied to `$SKYHOOK_DIR` (typically `/skyhook-package`). This means:

- `config.json` → `/skyhook-package/config.json`
- `skyhook_dir/` → `/skyhook-package/skyhook_dir/`
- `skyhook_dir/apply.sh` → `/skyhook-package/skyhook_dir/apply.sh`
- `skyhook_dir/steps/` → `/skyhook-package/skyhook_dir/steps/`

Environment variables set for scripts:
- `SKYHOOK_DIR`: `/skyhook-package` (package root)
- `STEP_ROOT`: `/skyhook-package/skyhook_dir` (scripts directory)

## Prerequisites

- Docker installed and running
- Python 3.8 or higher
- pip (Python package manager)

## Installation

Install Python test dependencies:

```bash
make test-deps
```

Or manually:

```bash
pip install -r tests/requirements.txt
```

## Running Tests

Run all tests (in parallel by default):

```bash
make test
```

Tests run in parallel automatically using pytest-xdist, which significantly speeds up execution. The worker count is auto-detected based on your CPU cores.

Override worker count:

```bash
TEST_WORKERS=4 make test
```

Run sequentially (for debugging):

```bash
./venv/bin/pytest tests/integration/ -n 0
```

Or using pytest directly:

```bash
pytest tests/integration/
```

Run specific test file:

```bash
pytest tests/integration/nvidia_setup/test_apply.py
```

Run specific test:

```bash
pytest tests/integration/nvidia_setup/test_apply.py::test_unsupported_combination
```

Run with verbose output and timing:

```bash
pytest tests/integration/ -v --durations=10 --durations-min=1.0
```

## Test Structure

```
tests/
├── helpers/
│   ├── docker_test.py      # DockerTestRunner class for container management
│   └── assertions.py        # Assertion utilities
├── integration/
│   └── nvidia_setup/
│       ├── test_apply.py           # Tests for apply.sh
│       ├── test_apply_check.py      # Tests for apply_check.sh
│       └── test_steps.py            # Tests for individual step scripts
├── requirements.txt         # Python dependencies
└── README.md               # This file
```

## Writing New Tests

### Basic Test Structure

```python
#!/usr/bin/env python3
"""Tests for my-package."""

import pytest
from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner

def test_my_script():
    """Test my script."""
    runner = DockerTestRunner(package="my-package")
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"key": "value"},
            env_vars={"ENV_VAR": "value"}
        )
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "expected output")
    finally:
        runner.cleanup()
```

### Using Context Manager

```python
def test_with_context_manager():
    """Test using context manager for automatic cleanup."""
    with DockerTestRunner(package="my-package") as runner:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "h100"}
        )
        assert_exit_code(result, 0)
```

### Available Assertions

- `assert_exit_code(result, expected)` - Validate script exit code
- `assert_output_contains(output, text)` - Check output contains text
- `assert_output_not_contains(output, text)` - Check output doesn't contain text
- `assert_file_exists(runner, path)` - Check file exists in container
- `assert_file_contains(runner, path, text)` - Check file contains text
- `assert_file_not_contains(runner, path, text)` - Check file doesn't contain text

### Test Matrix Configuration

Tests can be run against multiple container base images using a test matrix. Define the matrix in your package's `__init__.py`:

```python
# tests/integration/my_package/__init__.py
TEST_MATRIX = [
    "ubuntu:22.04",
    "ubuntu:20.04",
    "ubuntu:24.04",
]
```

Then add `base_image` parameter to your test functions:

```python
def test_my_script(base_image):
    """Test that runs against all images in TEST_MATRIX."""
    runner = DockerTestRunner(package="my-package", base_image=base_image)
    # ... rest of test
```

The test will automatically run once for each image in the matrix. Test names will include the image identifier (e.g., `test_my_script[ubuntu-22.04]`).

### DockerTestRunner Parameters

- `package` (required): Name of the package to test (e.g., "nvidia-setup")
- `base_image` (optional): Docker base image for test container (default: "ubuntu:24.04")

### run_script Parameters

- `script` (required): Path to script relative to skyhook_dir (e.g., "apply.sh" or "steps/upgrade.sh")
- `configmaps` (optional): Dictionary of configmap key-value pairs
- `env_vars` (optional): Dictionary of environment variables
- `skip_system_operations` (optional): If True, set SKIP_SYSTEM_OPERATIONS env var
- `script_args` (optional): List of arguments to pass to the script

### Accessing Container Files

```python
runner = DockerTestRunner(package="my-package")
try:
    # Run script
    result = runner.run_script(script="apply.sh")
    
    # Check if file exists
    if runner.file_exists("/path/to/file"):
        # Get file contents
        contents = runner.get_file_contents("/path/to/file")
        assert "expected text" in contents
finally:
    runner.cleanup()
```

## Test Conventions

1. **Always cleanup**: Use try/finally or context manager to ensure containers are cleaned up
2. **Use descriptive test names**: Test names should clearly describe what they test
3. **Skip system operations when possible**: Use `skip_system_operations=True` for faster tests that don't need actual package installations
4. **Test error cases**: Include tests for invalid inputs, missing files, etc.
5. **Isolate tests**: Each test should be independent and not rely on other tests

## Parallel Test Execution

Tests run in parallel by default using pytest-xdist, which significantly speeds up execution:

- **Automatic worker detection**: Uses `-n auto` to detect optimal worker count (typically CPU count)
- **Worker override**: Set `TEST_WORKERS` environment variable to specify worker count
- **Isolation**: Each test runs in its own Docker container, ensuring complete isolation
- **Resource usage**: Parallel execution uses more Docker resources (containers, memory, CPU)

**Examples:**
```bash
# Auto-detect workers (default)
make test

# Use 4 workers
TEST_WORKERS=4 make test

# Run sequentially (for debugging)
./venv/bin/pytest tests/integration/ -n 0
```

## Docker Container Details

- **Base Image**: Ubuntu 24.04 by default, configurable via test matrix
- **Environment Variables**: 
  - `SKYHOOK_DIR`: `/skyhook-package` (package root)
  - `STEP_ROOT`: `/skyhook-package/skyhook_dir` (scripts directory)
- **Package Files**: Entire package root copied to `/skyhook-package` in container
- **ConfigMaps**: Created in `/skyhook-package/configmaps/`
- **Cleanup**: Containers are automatically removed after tests
- **Isolation**: Each test gets its own container, enabling safe parallel execution

## CI Integration

Tests are designed to run in CI environments with Docker available. The framework:
- Automatically cleans up containers
- Handles container creation failures gracefully
- Provides clear error messages

## Troubleshooting

### Docker not running
```
Error: Cannot connect to Docker daemon
```
Solution: Start Docker daemon

### Container creation fails
```
Error: Failed to create container
```
Solution: Check Docker permissions and available resources

### Tests timeout
Some tests may take longer if they perform actual system operations. Consider using `skip_system_operations=True` for faster feedback during development.

### Import errors
```
ModuleNotFoundError: No module named 'tests.helpers'
```
Solution: Run tests from repository root, or ensure Python path includes repository root

### Parallel execution issues
If you encounter resource constraints with parallel execution:
- Reduce worker count: `TEST_WORKERS=2 make test`
- Run sequentially for debugging: `./venv/bin/pytest tests/integration/ -n 0`
- Check Docker resources: Ensure Docker has enough memory and CPU allocated

## Examples

See the test files in `tests/integration/nvidia_setup/` for complete examples of:
- Testing script execution
- Validating output
- Checking file contents
- Testing with different configurations
- Error handling
