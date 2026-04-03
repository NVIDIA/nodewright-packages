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
Assertion utilities for NodeWright package tests.

This module provides assertion functions for validating test results.
"""

from typing import Optional

import pytest

from tests.helpers.docker_test import DockerTestRunner, TestResult


def assert_exit_code(result: TestResult, expected: int):
    """
    Assert that the test result has the expected exit code.
    
    Args:
        result: TestResult object
        expected: Expected exit code
    """
    assert result.exit_code == expected, (
        f"Expected exit code {expected}, got {result.exit_code}\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )


def assert_output_contains(output: str, text: str):
    """
    Assert that output contains the specified text.
    
    Args:
        output: Output string to check
        text: Text that should be present
    """
    assert text in output, f"Expected output to contain '{text}', but got:\n{output}"


def assert_output_not_contains(output: str, text: str):
    """
    Assert that output does not contain the specified text.
    
    Args:
        output: Output string to check
        text: Text that should not be present
    """
    assert text not in output, f"Expected output not to contain '{text}', but got:\n{output}"


def assert_file_exists(runner: DockerTestRunner, path: str):
    """
    Assert that a file exists in the container.
    
    Args:
        runner: DockerTestRunner instance
        path: Path to file in container
    """
    assert runner.file_exists(path), f"Expected file {path} to exist in container"


def assert_file_contains(runner: DockerTestRunner, path: str, text: str):
    """
    Assert that a file in the container contains the specified text.
    
    Args:
        runner: DockerTestRunner instance
        path: Path to file in container
        text: Text that should be present in file
    """
    assert_file_exists(runner, path)
    contents = runner.get_file_contents(path)
    assert text in contents, (
        f"Expected file {path} to contain '{text}', but got:\n{contents}"
    )


def assert_file_not_contains(runner: DockerTestRunner, path: str, text: str):
    """
    Assert that a file in the container does not contain the specified text.
    
    Args:
        runner: DockerTestRunner instance
        path: Path to file in container
        text: Text that should not be present in file
    """
    assert_file_exists(runner, path)
    contents = runner.get_file_contents(path)
    assert text not in contents, (
        f"Expected file {path} not to contain '{text}', but got:\n{contents}"
    )
