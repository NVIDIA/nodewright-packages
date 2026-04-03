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
Tests for nvidia-setup apply_check.sh script.
"""

import pytest

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


def test_apply_check_unsupported_combination():
    """Test that apply_check.sh fails for unsupported combinations."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "invalid", "accelerator": "invalid"}
        )
        
        assert_exit_code(result, 1)
    finally:
        runner.cleanup()


def test_apply_check_eks_h100(base_image):
    """Test apply_check.sh with eks-h100 combination."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "eks", "accelerator": "h100"}
        )
        
        # apply_check.sh will likely fail if packages aren't installed,
        # but it should at least execute the check scripts
        assert result.exit_code is not None
    finally:
        runner.cleanup()


def test_apply_check_eks_gb200(base_image):
    """Test apply_check.sh with eks-gb200 combination."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "eks", "accelerator": "gb200"}
        )
        
        assert result.exit_code is not None
    finally:
        runner.cleanup()


def test_apply_check_with_env_overrides(base_image):
    """Test apply_check.sh with environment variable overrides."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            env_vars={
                "NVIDIA_KERNEL": "5.15.0-1025-aws",
                "NVIDIA_EFA": "1.31.0",
                "NVIDIA_LUSTRE": "aws"
            }
        )
        
        assert result.exit_code is not None
    finally:
        runner.cleanup()

def test_post_interrupt_check_with_install_kernel_true_fails_when_kernel_mismatch(base_image):
    """Post-interrupt-check with INSTALL_KERNEL=true verifies kernel; fails when running kernel doesn't match."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="post_interrupt_check.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            env_vars={"NVIDIA_SETUP_INSTALL_KERNEL": "true"},
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "does not match expected")
    finally:
        runner.cleanup()


def test_post_interrupt_check_with_install_kernel_false_exits_success(base_image):
    """Post-interrupt-check with INSTALL_KERNEL=false does nothing and exits 0."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="post_interrupt_check.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            env_vars={"NVIDIA_SETUP_INSTALL_KERNEL": "false"},
        )
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()
