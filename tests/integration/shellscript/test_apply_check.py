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
Tests for shellscript package apply-check mode.
"""

import pytest

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


def test_apply_check_success(base_image):
    """Test apply-check mode with a successful check script."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply_check"],
            configmaps={
                "apply_check.sh": """#!/bin/bash
echo "Apply check passed"
exit 0
"""
            }
        )
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Apply check passed")
    finally:
        runner.cleanup()


def test_apply_check_failure(base_image):
    """Test apply-check mode when check fails."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply_check"],
            configmaps={
                "apply_check.sh": """#!/bin/bash
echo "Apply check failed - missing dependency"
exit 1
"""
            }
        )
        
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "Apply check failed")
    finally:
        runner.cleanup()


def test_apply_check_missing_script(base_image):
    """Test apply-check mode when script is missing."""
    runner = DockerTestRunner(package="shellscript", base_image=base_image)
    try:
        result = runner.run_script(
            script="shellscript_run.sh",
            script_args=["apply_check"],
            configmaps={}  # No apply_check.sh
        )
        
        # shellscript_run.sh doesn't exit with error, just prints message
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Could not find file")
        assert_output_contains(result.stdout, "apply_check.sh")
    finally:
        runner.cleanup()
