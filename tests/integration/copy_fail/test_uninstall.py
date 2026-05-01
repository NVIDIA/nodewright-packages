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
Tests for copy-fail package uninstall mode.
"""

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
)
from tests.helpers.docker_test import DockerTestRunner


MODPROBE_FILE = "/etc/modprobe.d/disable-algif.conf"
CONFIG_SH = "/skyhook-package/skyhook_dir/config.sh"
UNINSTALL_SH = "/skyhook-package/skyhook_dir/uninstall.sh"
UNINSTALL_CHECK_SH = "/skyhook-package/skyhook_dir/uninstall_check.sh"


def test_uninstall_removes_modprobe_file(base_image):
    """uninstall.sh removes the modprobe blacklist file written by config.sh."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        applied = runner.run_script(script="config.sh")
        assert_exit_code(applied, 0)
        assert runner.file_exists(MODPROBE_FILE)

        result = runner.container.exec_run(["bash", UNINSTALL_SH])
        output = result.output.decode("utf-8", errors="replace")
        assert result.exit_code == 0, output
        assert not runner.file_exists(MODPROBE_FILE)
        assert f"removed {MODPROBE_FILE}" in output
    finally:
        runner.cleanup()


def test_uninstall_is_idempotent(base_image):
    """uninstall.sh succeeds even when the file is absent."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        result = runner.run_script(script="uninstall.sh")
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to remove")
    finally:
        runner.cleanup()


def test_uninstall_check_passes_when_file_absent(base_image):
    """uninstall_check.sh exits 0 when the file is not present."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        result = runner.run_script(script="uninstall_check.sh")
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "OK:")
    finally:
        runner.cleanup()


def test_uninstall_check_fails_when_file_present(base_image):
    """uninstall_check.sh exits non-zero when the file still exists."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        applied = runner.run_script(script="config.sh")
        assert_exit_code(applied, 0)

        result = runner.container.exec_run(["bash", UNINSTALL_CHECK_SH])
        output = result.output.decode("utf-8", errors="replace")
        assert result.exit_code == 1, output
        assert "still exists" in output
        assert "uninstall did not complete" in output
    finally:
        runner.cleanup()
