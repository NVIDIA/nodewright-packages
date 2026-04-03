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
Tests for check_kernel_at_least and check_kernel_exact in ensure_kernel.sh.

- at_least: compares upstream versions (before first '-'); current >= required passes.
- exact: current upstream must equal required upstream (NVIDIA_SETUP_KERNEL_ALLOW_NEWER=false behavior).
"""

from pathlib import Path

from tests.helpers.docker_test import DockerTestRunner

# Test script lives with tests and is copied into the package at run time
_CHECK_SCRIPT_SOURCE = Path(__file__).parent / "run_check_kernel_at_least_test.sh"
_CHECK_SCRIPT_DEST = "skyhook_dir/steps/run_check_kernel_at_least_test.sh"


def _run_check(
    runner: DockerTestRunner,
    current_kernel: str,
    required_kernel: str,
    mode: str = "at_least",
) -> int:
    """Run the check script; return exit code. mode is 'at_least' or 'exact'."""
    env = {
        "CURRENT_KERNEL": current_kernel,
        "REQUIRED_KERNEL": required_kernel,
    }
    if mode != "at_least":
        env["KERNEL_CHECK_MODE"] = mode
    result = runner.run_script(
        script="steps/run_check_kernel_at_least_test.sh",
        configmaps={},
        env_vars=env,
        extra_files=[(_CHECK_SCRIPT_SOURCE, _CHECK_SCRIPT_DEST)],
    )
    return result.exit_code


# --- check_kernel_at_least (allow newer: current >= required) ---


def test_at_least_current_newer_upstream_passes():
    """6.17.0-1007-aws >= 6.14.0-1018-aws (upstream 6.17 >= 6.14); was previously failing with sort -V on full string."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.17.0-1007-aws", "6.14.0-1018-aws", mode="at_least")
        assert exit_code == 0
    finally:
        runner.cleanup()


def test_at_least_current_same_upstream_passes():
    """6.14.0-1000-aws >= 6.14.0-1018-aws (same upstream)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.14.0-1000-aws", "6.14.0-1018-aws", mode="at_least")
        assert exit_code == 0
    finally:
        runner.cleanup()


def test_at_least_current_older_upstream_fails():
    """6.13.0-1000-aws < 6.14.0-1018-aws (upstream 6.13 < 6.14)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.13.0-1000-aws", "6.14.0-1018-aws", mode="at_least")
        assert exit_code == 1
    finally:
        runner.cleanup()


def test_at_least_current_exact_required_passes():
    """6.14.0-1018-aws >= 6.14.0-1018-aws (equal)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.14.0-1018-aws", "6.14.0-1018-aws", mode="at_least")
        assert exit_code == 0
    finally:
        runner.cleanup()


# --- check_kernel_exact (exact upstream match; NVIDIA_SETUP_KERNEL_ALLOW_NEWER=false) ---


def test_exact_current_newer_upstream_fails():
    """6.17.0-1007-aws vs 6.14.0-1018-aws: exact requires same upstream, so fails."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.17.0-1007-aws", "6.14.0-1018-aws", mode="exact")
        assert exit_code == 1
    finally:
        runner.cleanup()


def test_exact_current_same_upstream_passes():
    """6.14.0-1000-aws vs 6.14.0-1018-aws: same upstream 6.14.0, exact passes."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.14.0-1000-aws", "6.14.0-1018-aws", mode="exact")
        assert exit_code == 0
    finally:
        runner.cleanup()


def test_exact_current_older_upstream_fails():
    """6.13.0-1000-aws vs 6.14.0-1018-aws: different upstream, exact fails."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.13.0-1000-aws", "6.14.0-1018-aws", mode="exact")
        assert exit_code == 1
    finally:
        runner.cleanup()


def test_exact_current_exact_required_passes():
    """6.14.0-1018-aws vs 6.14.0-1018-aws: exact match passes."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        exit_code = _run_check(runner, "6.14.0-1018-aws", "6.14.0-1018-aws", mode="exact")
        assert exit_code == 0
    finally:
        runner.cleanup()
