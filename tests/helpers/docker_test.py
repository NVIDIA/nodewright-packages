#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Docker test runner for NodeWright packages.

This module provides a DockerTestRunner class that manages Docker containers
for testing NodeWright package scripts in isolated environments.
"""

import os
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

import docker

from tests.helpers.base_images import assert_image_present, resolve_base_image


@dataclass
class TestResult:
    """Result of a test script execution."""
    exit_code: int
    stdout: str
    stderr: str
    container_id: str


class DockerTestRunner:
    """Manages Docker containers for testing NodeWright packages."""
    
    def __init__(self, package: str, base_image: str = "ubuntu:24.04"):
        """
        Initialize the Docker test runner.
        
        Args:
            package: Name of the package to test (e.g., "nvidia-setup")
            base_image: Docker base image to use (default: ubuntu:24.04)
        """
        self.package = package
        self.requested_base_image = base_image
        self.client = docker.from_env()
        # Packages may declare a prebuilt test base image (see
        # tests/helpers/base_images.py). Resolving here means no test file has to
        # know whether its package opts in, and it covers every container-creation
        # path -- including the ones that call containers.run directly rather than
        # going through run_script.
        self.base_image = resolve_base_image(package, base_image)
        if self.base_image != base_image:
            assert_image_present(self.client, self.base_image, package)
        self.container = None
        self.temp_dir = None
        self._package_path = Path(__file__).parent.parent.parent / package
        
        if not self._package_path.exists():
            raise ValueError(f"Package directory not found: {self._package_path}")
    
    def _create_temp_directory(self) -> Path:
        """Create a temporary directory for test files."""
        if self.temp_dir is None:
            self.temp_dir = tempfile.mkdtemp(prefix="skyhook-test-")
        return Path(self.temp_dir)
    
    def _setup_package_environment(
        self,
        configmaps: Optional[Dict[str, str]] = None,
        extra_files: Optional[List[Tuple[Union[str, Path], str]]] = None,
    ) -> Path:
        """
        Set up the package environment in a temporary directory.

        The package root gets copied to SKYHOOK_DIR (/skyhook-package).
        This matches how packages are structured in production.

        Args:
            configmaps: Dictionary of configmap key-value pairs
            extra_files: Optional list of (source_path, dest_relative_to_skyhook_package)
                         to copy into the package (e.g. test scripts from tests/).

        Returns:
            Path to the skyhook-package directory
        """
        temp_dir = self._create_temp_directory()
        skyhook_package_dir = temp_dir / "skyhook-package"

        # Copy entire package directory structure to skyhook-package
        # This matches the package Dockerfile: COPY . /skyhook-package
        # In production, everything from /skyhook-package/* in the container image
        # gets copied to /root/${SKYHOOK_DIR} on the host filesystem
        shutil.copytree(self._package_path, skyhook_package_dir, dirs_exist_ok=True)

        # Copy extra files (e.g. test scripts from tests/) into the package
        if extra_files:
            for src, dest_rel in extra_files:
                src_path = Path(src)
                if not src_path.is_file():
                    raise ValueError(f"extra_files source not a file: {src_path}")
                dest_path = skyhook_package_dir / dest_rel
                dest_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_path, dest_path)
                if dest_rel.endswith(".sh"):
                    dest_path.chmod(0o755)

        # Make all .sh scripts executable (entry script and any scripts it invokes)
        for sh_file in skyhook_package_dir.rglob("*.sh"):
            sh_file.chmod(0o755)
        
        # Create configmaps directory and write configmaps
        configmaps_dir = skyhook_package_dir / "configmaps"
        configmaps_dir.mkdir(parents=True, exist_ok=True)
        
        if configmaps:
            for key, value in configmaps.items():
                configmap_file = configmaps_dir / key
                configmap_file.write_text(value)
        
        # Create node-metadata directory (optional, but some scripts may expect it)
        node_metadata_dir = skyhook_package_dir / "node-metadata"
        node_metadata_dir.mkdir(parents=True, exist_ok=True)
        
        return skyhook_package_dir
    
    def wait_until_ready(self, timeout: float = 30.0):
        """Poll until the container accepts exec and the package mount is visible.

        Replaces a flat `time.sleep(1)`, which was both wasteful (paid once per
        test) and a latent flake: a container that needed 1.1s would fail.
        """
        deadline = time.monotonic() + timeout
        last_error = None

        while time.monotonic() < deadline:
            try:
                probe = self.container.exec_run(["test", "-d", "/skyhook-package"], workdir="/")
                if probe.exit_code == 0:
                    return
            except Exception as exc:  # container not accepting exec yet
                last_error = exc
            time.sleep(0.05)

        detail = f" (last error: {last_error})" if last_error else ""
        raise RuntimeError(
            f"Container {self.container.id[:12]} never became ready within "
            f"{timeout}s{detail}.\n"
            f"If /skyhook-package is empty, the Docker daemon cannot see "
            f"{self.temp_dir!r}. On macOS (colima or Docker Desktop) TMPDIR must be "
            f"a path the daemon shares; the default /var/folders/... is not. Try:\n"
            f'    export TMPDIR="$HOME/.cache/skyhook-tests"'
        )

    def run_script(
        self,
        script: str,
        configmaps: Optional[Dict[str, str]] = None,
        env_vars: Optional[Dict[str, str]] = None,
        skip_system_operations: bool = False,
        script_args: Optional[List[str]] = None,
        extra_files: Optional[List[Tuple[Union[str, Path], str]]] = None,
    ) -> TestResult:
        """
        Run a script in a Docker container.

        Args:
            script: Path to script relative to skyhook_dir (e.g., "apply.sh" or "steps/upgrade.sh")
            configmaps: Dictionary of configmap key-value pairs
            env_vars: Dictionary of additional environment variables
            skip_system_operations: If True, set SKIP_SYSTEM_OPERATIONS flag
            script_args: Optional list of arguments to pass to the script
            extra_files: Optional list of (source_path, dest_relative_to_skyhook_package)
                         to copy into the package before running (e.g. test scripts from tests/)

        Returns:
            TestResult object with exit code, stdout, stderr, and container_id
        """
        # Set up package environment
        skyhook_package_dir = self._setup_package_environment(
            configmaps=configmaps, extra_files=extra_files
        )
        
        # Set up environment variables
        container_env = {
            "SKYHOOK_DIR": "/skyhook-package",
            "STEP_ROOT": "/skyhook-package/skyhook_dir",
        }
        
        if skip_system_operations:
            container_env["SKIP_SYSTEM_OPERATIONS"] = "true"
        
        if env_vars:
            container_env.update(env_vars)
        
        # Determine script path
        # Scripts are in skyhook_dir, so handle both direct and subdirectory paths
        if script.startswith("steps/") or script.startswith("steps_check/"):
            script_path = f"/skyhook-package/skyhook_dir/{script}"
        else:
            script_path = f"/skyhook-package/skyhook_dir/{script}"
        
        # Create container with bind mount
        try:
            self.container = self.client.containers.run(
                self.base_image,
                command=["/bin/bash", "-c", "tail -f /dev/null"],  # Keep container running
                detach=True,
                environment=container_env,
                volumes={
                    str(skyhook_package_dir): {
                        "bind": "/skyhook-package",
                        "mode": "rw"
                    }
                },
                remove=False,
                tty=False,
                stdin_open=False
            )
            
            # Wait for container to be ready
            self.wait_until_ready()
            
            # Verify script exists in container
            check_result = self.container.exec_run(
                ["test", "-f", script_path],
                workdir="/"
            )
            
            if check_result.exit_code != 0:
                # List directories to debug
                ls_root = self.container.exec_run(
                    ["ls", "-la", "/skyhook-package/"],
                    workdir="/"
                )
                ls_skyhook_dir = self.container.exec_run(
                    ["ls", "-la", "/skyhook-package/skyhook_dir/"],
                    workdir="/"
                ) if self.container.exec_run(["test", "-d", "/skyhook-package/skyhook_dir"], workdir="/").exit_code == 0 else None
                
                root_output = ls_root.output.decode('utf-8', errors='replace')
                skyhook_output = ls_skyhook_dir.output.decode('utf-8', errors='replace') if ls_skyhook_dir else "Directory does not exist"
                
                raise RuntimeError(
                    f"Script {script_path} not found in container.\n"
                    f"Container /skyhook-package/ contents: {root_output}\n"
                    f"Container /skyhook-package/skyhook_dir/ contents: {skyhook_output}"
                )
            
            # Make script executable
            exec_result = self.container.exec_run(
                ["chmod", "+x", script_path],
                workdir="/skyhook-package"
            )
            
            if exec_result.exit_code != 0:
                raise RuntimeError(f"Failed to make script executable: {exec_result.output.decode()}")
            
            # Execute the script
            # Build command with arguments if provided
            if script_args:
                args_str = " ".join(f'"{arg}"' for arg in script_args)
                cmd = f"{script_path} {args_str} 2>&1"
            else:
                cmd = f"{script_path} 2>&1"
            
            exec_result = self.container.exec_run(
                ["/bin/bash", "-c", cmd],
                workdir="/skyhook-package",
                environment=container_env
            )
            
            # exec_run combines stdout and stderr, so we get everything in output
            output = exec_result.output.decode('utf-8', errors='replace')
            
            return TestResult(
                exit_code=exec_result.exit_code,
                stdout=output,
                stderr="",  # Combined into stdout via 2>&1
                container_id=self.container.id
            )
            
        except Exception as e:
            # Clean up on error
            self.cleanup()
            raise RuntimeError(f"Failed to run script in container: {e}") from e
    
    def get_file_contents(self, file_path: str) -> str:
        """
        Get contents of a file from the container.
        
        Args:
            file_path: Path to file in container
            
        Returns:
            File contents as string
        """
        if not self.container:
            raise RuntimeError("No container available")
        
        exec_result = self.container.exec_run(["cat", file_path])
        if exec_result.exit_code != 0:
            raise RuntimeError(f"Failed to read file {file_path}: {exec_result.output.decode()}")
        
        return exec_result.output.decode('utf-8', errors='replace')
    
    def file_exists(self, file_path: str) -> bool:
        """
        Check if a file exists in the container.
        
        Args:
            file_path: Path to file in container
            
        Returns:
            True if file exists, False otherwise
        """
        if not self.container:
            return False
        
        exec_result = self.container.exec_run(["test", "-f", file_path])
        return exec_result.exit_code == 0
    
    def cleanup(self):
        """Clean up Docker container and temporary files."""
        if self.container:
            try:
                # Go straight to SIGKILL. PID 1 in these containers is `tail`,
                # which installs no SIGTERM handler, and the kernel ignores
                # default-disposition signals for PID 1, so a graceful stop()
                # burned its full timeout (measured 5.25s) on every test before
                # the SIGKILL landed. Nothing here holds state worth flushing.
                self.container.remove(force=True)
            except Exception:
                pass  # Ignore cleanup errors
            finally:
                self.container = None
        
        if self.temp_dir and os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir, ignore_errors=True)
            self.temp_dir = None
    
    def __enter__(self):
        """Context manager entry."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - cleanup."""
        self.cleanup()
