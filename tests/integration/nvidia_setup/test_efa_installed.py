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
Tests for efa_driver_installed and efa_driver_current in utilities.sh.

install-efa-driver.sh skips when EFA from the configured installer is already
installed, and install_efa_driver_check.sh passes on the same condition, so both
ask efa_driver_current. It must answer on evidence that EFA installed, not on
traces a failed install leaves behind, and an installed EFA from another
installer version is not current.

The harness stubs dpkg-query, dkms and ldconfig, so no scenario inspects the
real package database.
"""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

_HARNESS_SOURCE = Path(__file__).parent / "run_efa_installed_test.sh"
_HARNESS_DEST = "skyhook_dir/steps/run_efa_installed_test.sh"


def _run_scenario(scenario: str) -> int:
    """Run one harness scenario; return its exit code (0 = behaved as specified)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="steps/run_efa_installed_test.sh",
            configmaps={},
            env_vars={"SCENARIO": scenario},
            extra_files=[(_HARNESS_SOURCE, _HARNESS_DEST)],
        )
        return result.exit_code
    finally:
        runner.cleanup()


def test_fully_installed_efa_is_installed():
    """The one state that counts: package configured and module built."""
    assert _run_scenario("efa_installed") == 0


@pytest.mark.parametrize(
    "scenario",
    [
        # The reported failure: a DKMS postinstall aborted and dpkg parked the
        # package half-configured, so EFA is not installed.
        "efa_half_configured",
        "efa_unpacked",
        "efa_absent",
    ],
)
def test_package_not_configured_is_not_installed(scenario):
    assert _run_scenario(scenario) == 0


@pytest.mark.parametrize(
    "scenario",
    ["efa_dkms_added_not_installed", "efa_dkms_no_entry"],
)
def test_module_not_built_is_not_installed(scenario):
    """A configured package whose kernel module was never built is not an install."""
    assert _run_scenario(scenario) == 0


@pytest.mark.parametrize(
    "scenario",
    ["efa_leftover_directory_is_not_proof", "efa_libfabric_is_not_proof"],
)
def test_traces_are_not_proof_of_installation(scenario):
    """Regression guards: /opt/amazon/efa and a stray libfabric used to mean 'skip'."""
    assert _run_scenario(scenario) == 0


def test_efa_from_configured_installer_is_current():
    assert _run_scenario("efa_current_when_recorded_installer_matches") == 0


@pytest.mark.parametrize(
    "scenario",
    [
        # Every node set up before the record existed, so it upgrades once.
        "efa_not_current_without_record",
        "efa_not_current_when_recorded_installer_differs",
        # The record says what ran, not what is installed now.
        "efa_not_current_when_not_installed",
    ],
)
def test_efa_not_from_configured_installer_is_not_current(scenario):
    """An installed efa 3.0.0 cannot build for the 7.0 kernels, so installed alone is not enough."""
    assert _run_scenario(scenario) == 0


@pytest.mark.parametrize(
    "scenario",
    ["efa_dkms_registered_in_any_state", "efa_dkms_not_registered"],
)
def test_efa_dkms_registered(scenario):
    """Any efa module dkms knows is one it builds for a newly installed kernel."""
    assert _run_scenario(scenario) == 0
