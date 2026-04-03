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
Pytest configuration and fixtures for NodeWright packages tests.
"""

import pytest
from typing import Union, Dict, List

from tests.helpers.docker_test import DockerTestRunner


def get_test_matrix(package_name: str) -> List[Union[str, Dict]]:
    """
    Get the test matrix for a package.
    
    Args:
        package_name: Name of the package (e.g., "nvidia_setup")
        
    Returns:
        List of base images or configurations to test against
    """
    try:
        # Import the package's test module
        module = __import__(f"tests.integration.{package_name}", fromlist=["TEST_MATRIX"])
        return getattr(module, "TEST_MATRIX", ["ubuntu:22.04"])
    except (ImportError, AttributeError):
        # Default to ubuntu:22.04 if no matrix is defined
        return ["ubuntu:22.04"]


def normalize_matrix_entry(entry: Union[str, Dict]) -> Dict:
    """
    Normalize a matrix entry to a dict format.
    
    Args:
        entry: Either a string (base_image) or dict with base_image key
        
    Returns:
        Dict with at least 'base_image' key
    """
    if isinstance(entry, str):
        return {"base_image": entry, "name": entry.replace(":", "-")}
    return entry


@pytest.fixture(scope="function")
def docker_runner(request):
    """
    Pytest fixture that provides a DockerTestRunner with matrix support.
    
    Usage:
        def test_my_script(docker_runner):
            runner = docker_runner(package="nvidia-setup")
            # ... use runner
    """
    def _create_runner(package: str, base_image: str = None):
        """
        Create a DockerTestRunner instance.
        
        Args:
            package: Package name (e.g., "nvidia-setup")
            base_image: Optional base image override
            
        Returns:
            DockerTestRunner instance
        """
        if base_image is None:
            # Default to ubuntu:22.04
            base_image = "ubuntu:22.04"
        return DockerTestRunner(package=package, base_image=base_image)
    
    return _create_runner


def pytest_generate_tests(metafunc):
    """
    Pytest hook to parametrize tests based on TEST_MATRIX.
    
    If a test function has a 'base_image' parameter, it will be parametrized
    with all entries from the package's TEST_MATRIX.
    """
    # Check if test function has 'base_image' parameter
    if "base_image" in metafunc.fixturenames or hasattr(metafunc.function, "pytestmark"):
        # Check if base_image is in the function signature
        import inspect
        sig = inspect.signature(metafunc.function)
        if "base_image" in sig.parameters:
            # Try to determine package name from test module path
            test_module = metafunc.module
            module_path = test_module.__name__
            
            # Extract package name from module path (e.g., "tests.integration.nvidia_setup.test_apply" -> "nvidia_setup")
            if "integration" in module_path:
                parts = module_path.split(".")
                if len(parts) >= 3:
                    package_name = parts[2]  # e.g., "nvidia_setup"
                    
                    # Get test matrix for this package
                    matrix = get_test_matrix(package_name)
                    
                    # Normalize entries and extract base_image values
                    base_images = [normalize_matrix_entry(entry)["base_image"] for entry in matrix]
                    
                    # Generate IDs for better test names
                    ids = [normalize_matrix_entry(entry).get("name", img.replace(":", "-")) for entry, img in zip(matrix, base_images)]
                    
                    # Parametrize the test
                    metafunc.parametrize("base_image", base_images, ids=ids)
