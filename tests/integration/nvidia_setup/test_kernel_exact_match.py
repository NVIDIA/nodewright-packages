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
Tests for the exact-match short circuit in steps/install_kernel.sh.

With NVIDIA_SETUP_INSTALL_KERNEL=true, install_kernel.sh ran an apt transaction
even on a node already booted on the target kernel with every target package
installed. That made an idempotent step depend on the network, the archive and
a healthy dpkg database. On NVIDIA/aicr#2870 it inherited unrelated dpkg damage
and failed node tuning.

The harness stubs uname, apt-get, dpkg, dpkg-query and the GRUB tools, so
install_kernel.sh runs end to end without touching the system.
"""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

_HARNESS_SOURCE = Path(__file__).parent / "run_kernel_exact_match_test.sh"
_HARNESS_DEST = "skyhook_dir/steps/run_kernel_exact_match_test.sh"


def _run_scenario(scenario: str) -> int:
    """Run one harness scenario; return its exit code (0 = behaved as specified)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="steps/run_kernel_exact_match_test.sh",
            configmaps={},
            env_vars={"SCENARIO": scenario},
            extra_files=[(_HARNESS_SOURCE, _HARNESS_DEST)],
        )
        if result.exit_code != 0:
            print(result.stdout)
        return result.exit_code
    finally:
        runner.cleanup()


@pytest.mark.parametrize(
    "scenario",
    [
        "skips_apt_on_target",
        # arm64 targets the -64k flavor, so that is what counts as a match.
        "skips_apt_on_target_arm64",
    ],
)
def test_apt_is_skipped_on_target_kernel(scenario):
    assert _run_scenario(scenario) == 0


def test_unrelated_dpkg_damage_does_not_fail_a_node_on_target():
    """The aicr#2870 failure: the redundant apt call inherited damage it had no need to touch."""
    assert _run_scenario("succeeds_on_target_despite_unrelated_dpkg_damage") == 0


def test_grub_default_is_still_set_when_apt_is_skipped():
    """GRUB still defaults to the target, so a later kernel install cannot take over the boot."""
    assert _run_scenario("keeps_grub_default_when_skipping") == 0


@pytest.mark.parametrize(
    "scenario",
    [
        "installs_when_running_other_kernel",
        # Headers are what nvidia-setup-full's EFA DKMS build needs.
        "installs_when_target_package_missing",
        # Same upstream version, 4k flavor: an upstream-only comparison would match.
        "installs_when_arm64_runs_4k_flavor",
    ],
)
def test_kernel_is_installed_when_not_an_exact_match(scenario):
    assert _run_scenario(scenario) == 0
