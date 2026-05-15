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
Tests for nvidia-setup apply.sh script.
"""

import pytest

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
    assert_output_not_contains,
)
from tests.helpers.docker_test import DockerTestRunner


def test_unsupported_combination():
    """Test that unsupported service/accelerator combinations fail with proper error."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "invalid", "accelerator": "invalid"}
        )
        
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "Unsupported combination")
        assert_output_contains(result.stdout, "Supported:")
    finally:
        runner.cleanup()

@pytest.mark.skip(reason="Skipping test_apply_eks_h100. Kernel is flaky based on where it is run.")
def test_apply_eks_h100(base_image):
    """Test apply.sh with eks-h100 combination."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            skip_system_operations=True
        )
        
        # Should exit successfully (even if system operations are skipped)
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()

@pytest.mark.skip(reason="Skipping test_apply_eks_gb200. Kernel is flaky based on where it is run.")
def test_apply_eks_gb200(base_image):
    """Test apply.sh with eks-gb200 combination."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "gb200"},
            skip_system_operations=True
        )
        
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()


def test_apply_with_env_overrides(base_image):
    """Test apply.sh with environment variable overrides."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            env_vars={
                "NVIDIA_KERNEL": "6.8.0",
                "NVIDIA_SETUP_KERNEL_ALLOW_NEWER": "true",  # container kernel may be newer than override
                "NVIDIA_EFA": "1.31.0",
                "NVIDIA_LUSTRE": "aws"
            },
            skip_system_operations=True
        )
        
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()


def test_apply_missing_configmap():
    """Test apply.sh with missing configmap files."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        # Run with empty configmaps to simulate missing files
        result = runner.run_script(
            script="apply.sh",
            configmaps={},
            skip_system_operations=True
        )
        
        # Should fail because service and accelerator are required
        assert_exit_code(result, 1)
    finally:
        runner.cleanup()


def test_apply_dynamic_supported_listing(base_image):
    """Test that apply.sh dynamically lists supported combinations from defaults directory."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "invalid", "accelerator": "invalid"}
        )

        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "eks-h100")
        assert_output_contains(result.stdout, "eks-gb200")
        assert_output_contains(result.stdout, "aks-h100")
    finally:
        runner.cleanup()


def test_apply_install_kernel_only_skips_actual_install(base_image):
    """With NVIDIA_SETUP_INSTALL_KERNEL=true and SKIP_SYSTEM_OPERATIONS, apply runs kernel-only path but skips real install/reboot."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            env_vars={"NVIDIA_SETUP_INSTALL_KERNEL": "true"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Skipping kernel install for test environment")
    finally:
        runner.cleanup()


def test_apply_install_kernel_only_eks_gb200_skips_actual_install(base_image):
    """Kernel-only path with eks-gb200; skips actual install when SKIP_SYSTEM_OPERATIONS set."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "eks", "accelerator": "gb200"},
            env_vars={"NVIDIA_SETUP_INSTALL_KERNEL": "true"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Skipping kernel install for test environment")
    finally:
        runner.cleanup()
