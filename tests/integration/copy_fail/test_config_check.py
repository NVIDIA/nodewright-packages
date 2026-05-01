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
Tests for copy-fail package config-check mode.
"""

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
)
from tests.helpers.docker_test import DockerTestRunner


MODPROBE_FILE = "/etc/modprobe.d/disable-algif.conf"
CONFIG_SH = "/skyhook-package/skyhook_dir/config.sh"
CONFIG_CHECK_SH = "/skyhook-package/skyhook_dir/config_check.sh"


def test_check_fails_when_file_missing(base_image):
    """config_check.sh exits non-zero when the modprobe file is absent."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        result = runner.run_script(script="config_check.sh")

        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "does not exist")
        assert_output_contains(result.stdout, "mitigation is not applied")
    finally:
        runner.cleanup()


def test_check_passes_after_config(base_image):
    """After config.sh runs, config_check.sh in the same container exits 0."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        applied = runner.run_script(script="config.sh")
        assert_exit_code(applied, 0)

        check = runner.container.exec_run(
            ["bash", CONFIG_CHECK_SH],
            environment={"ALLOW_LOADED_MODULE": "false"},
        )
        output = check.output.decode("utf-8", errors="replace")
        assert check.exit_code == 0, output
        assert "OK:" in output
    finally:
        runner.cleanup()


def test_check_fails_when_file_has_wrong_content(base_image):
    """config_check.sh exits non-zero when the file exists but contents do not match."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        applied = runner.run_script(script="config.sh")
        assert_exit_code(applied, 0)

        # Corrupt the modprobe file out-of-band.
        runner.container.exec_run(
            ["sh", "-c", f"echo wrong-content > {MODPROBE_FILE}"]
        )

        check = runner.container.exec_run(["bash", CONFIG_CHECK_SH])
        output = check.output.decode("utf-8", errors="replace")
        assert check.exit_code == 1, output
        assert "does not contain the expected line" in output
    finally:
        runner.cleanup()


def test_check_allow_loaded_module_env_true(base_image):
    """ALLOW_LOADED_MODULE=true keeps the check at exit 0; in-container the module is unloaded anyway."""
    runner = DockerTestRunner(package="copy-fail", base_image=base_image)
    try:
        applied = runner.run_script(script="config.sh")
        assert_exit_code(applied, 0)

        check = runner.container.exec_run(
            ["bash", CONFIG_CHECK_SH],
            environment={"ALLOW_LOADED_MODULE": "true"},
        )
        output = check.output.decode("utf-8", errors="replace")
        assert check.exit_code == 0, output
    finally:
        runner.cleanup()
