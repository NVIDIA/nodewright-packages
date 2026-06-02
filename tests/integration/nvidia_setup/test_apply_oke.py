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

"""Tests for nvidia-setup oke flavor."""
from pathlib import Path

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


def test_oke_listed_in_supported():
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "invalid", "accelerator": "invalid"},
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "oke-h100")
        assert_output_contains(result.stdout, "oke-gb200")
    finally:
        runner.cleanup()


def test_resolve_full_kernel_oracle_unchanged():
    wrapper = Path(__file__).parent / "fixtures" / "resolve_kernel_wrapper.sh"
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="_test_resolve_kernel.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            extra_files=[(wrapper, "skyhook_dir/_test_resolve_kernel.sh")],
            script_args=["6.8.0-1041-oracle"],
        )
        assert_exit_code(result, 0)
        assert "6.8.0-1041-oracle" in result.stdout
        assert "-aws" not in result.stdout
    finally:
        runner.cleanup()
