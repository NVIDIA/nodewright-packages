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
Tests for copy-fail package config mode.
"""

from tests.helpers.assertions import (
    assert_exit_code,
    assert_file_contains,
    assert_file_exists,
    assert_output_contains,
)
from tests.helpers.docker_test import DockerTestRunner


MODPROBE_FILE = "/etc/modprobe.d/disable-algif.conf"
EXPECTED_LINE = "install algif_aead /bin/false"
CONFIG_SH = "/skyhook-package/skyhook_dir/config.sh"


def test_config_writes_modprobe_file(base_image):
    """config.sh writes the modprobe blacklist file with the expected content."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        result = runner.run_script(script="config.sh")

        assert_exit_code(result, 0)
        assert_file_exists(runner, MODPROBE_FILE)
        assert_file_contains(runner, MODPROBE_FILE, EXPECTED_LINE)
        assert_output_contains(result.stdout, f"wrote {MODPROBE_FILE}")
    finally:
        runner.cleanup()


def test_config_rmmod_skipped_when_module_not_loaded(base_image):
    """In a container, algif_aead is not in /proc/modules; the rmmod branch is the 'skipped' one."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        result = runner.run_script(script="config.sh")

        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "rmmod algif_aead")
    finally:
        runner.cleanup()


def test_config_is_idempotent(base_image):
    """Running config.sh a second time in the same container is a no-op on the file."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        first = runner.run_script(script="config.sh")
        assert_exit_code(first, 0)

        second = runner.container.exec_run(["bash", CONFIG_SH])
        assert second.exit_code == 0, second.output.decode("utf-8", errors="replace")

        assert_file_exists(runner, MODPROBE_FILE)
        assert_file_contains(runner, MODPROBE_FILE, EXPECTED_LINE)
    finally:
        runner.cleanup()
