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
Tests for shellscript package apply mode.
"""

import pytest

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
    assert_output_not_contains,
)
from tests.helpers.docker_test import DockerTestRunner


def test_apply_success(base_image):
    """Test apply mode with a simple successful script."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply"],
            configmaps={
                "apply.sh": """#!/bin/bash
echo "Apply script executed successfully"
exit 0
"""
            }
        )
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Apply script executed successfully")
    finally:
        runner.cleanup()


def test_apply_missing_script(base_image):
    """Test apply mode when the script is missing from configmaps."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply"],
            configmaps={}  # No apply.sh script
        )
        
        # shellscript_run.sh doesn't exit with error, just prints message
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Could not find file")
        assert_output_contains(result.stdout, "apply.sh")
    finally:
        runner.cleanup()


def test_apply_script_with_error(base_image):
    """Test apply mode when the script exits with an error."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply"],
            configmaps={
                "apply.sh": """#!/bin/bash
echo "This script will fail"
exit 1
"""
            }
        )
        
        # The script itself exits with 1, but shellscript_run.sh should still exit 0
        # because it just sources the script
        # Actually, if the script exits 1, the sourcing will cause the parent to exit 1
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "This script will fail")
    finally:
        runner.cleanup()


def test_apply_script_uses_environment_variables(base_image):
    """Test that apply script can access SKYHOOK_DIR and STEP_ROOT."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply"],
            configmaps={
                "apply.sh": """#!/bin/bash
echo "SKYHOOK_DIR=${SKYHOOK_DIR}"
echo "STEP_ROOT=${STEP_ROOT}"
if [ -n "${SKYHOOK_DIR}" ] && [ -n "${STEP_ROOT}" ]; then
    echo "Environment variables are set correctly"
    exit 0
else
    echo "Environment variables are missing"
    exit 1
fi
"""
            }
        )
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "SKYHOOK_DIR=/skyhook-package")
        assert_output_contains(result.stdout, "STEP_ROOT=/skyhook-package/skyhook_dir")
        assert_output_contains(result.stdout, "Environment variables are set correctly")
    finally:
        runner.cleanup()


def test_apply_creates_file(base_image):
    """Test that apply script can create files."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply"],
            configmaps={
                "apply.sh": """#!/bin/bash
echo "Creating test file"
echo "test content" > /tmp/shellscript_test.txt
exit 0
"""
            }
        )
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Creating test file")
        
        # Verify file was created
        assert runner.file_exists("/tmp/shellscript_test.txt")
        contents = runner.get_file_contents("/tmp/shellscript_test.txt")
        assert "test content" in contents
    finally:
        runner.cleanup()
