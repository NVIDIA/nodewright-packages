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
Tests for the NVIDIA_SETUP_APT_UPGRADE gate in steps/upgrade.sh.

A blanket `apt-get upgrade` installs whatever the distro has queued, which on a
long-lived node includes the container runtime. Upgrading containerd restarts
it, killing the pod running this step: the node goes NotReady mid-apply and dpkg
is interrupted partway through a transaction. Observed on a GB300 node, which
went NotReady for ~9 minutes with "container runtime is down".

The harness stubs apt-get, dpkg and dpkg-query and points DPKG_ADMINDIR at a
scratch tree, so upgrade.sh runs end to end without touching the system.
"""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

_HARNESS_SOURCE = Path(__file__).parent / "run_upgrade_gate_test.sh"
_HARNESS_DEST = "skyhook_dir/steps/run_upgrade_gate_test.sh"


def _run_scenario(scenario: str) -> int:
    """Run one harness scenario; return its exit code (0 = behaved as specified)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="steps/run_upgrade_gate_test.sh",
            configmaps={},
            env_vars={"SCENARIO": scenario},
            extra_files=[(_HARNESS_SOURCE, _HARNESS_DEST)],
        )
        return result.exit_code
    finally:
        runner.cleanup()


def test_upgrade_is_skipped_by_default():
    """The default must not run a blanket upgrade; that is what took a node down."""
    assert _run_scenario("upgrade_skipped_by_default") == 0


def test_upgrade_runs_when_opted_in():
    """NVIDIA_SETUP_APT_UPGRADE=true still gets the full distro upgrade."""
    assert _run_scenario("upgrade_runs_when_enabled") == 0


@pytest.mark.parametrize(
    "scenario",
    [
        "upgrade_skipped_when_false",
        # Only the exact string "true" opts in; "yes" must not be read as truthy.
        "upgrade_skipped_on_non_true_value",
    ],
)
def test_upgrade_stays_off_for_anything_but_true(scenario):
    assert _run_scenario(scenario) == 0


def test_targeted_install_still_runs():
    """The gate must not take out the curl/git/wget/gpg install later steps need."""
    assert _run_scenario("install_still_runs_when_upgrade_skipped") == 0
