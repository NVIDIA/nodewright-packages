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
Tests for dpkg_needs_configure, dpkg_repair, dkms_remove_stale and
apt_with_dpkg_heal in utilities.sh.

apt refuses to run when dpkg was interrupted ("E: dpkg was interrupted, you must
manually run 'dpkg --configure -a'"), on any command that takes the dpkg lock,
apt-get update included. Every apt call in the package is wrapped so that state
is repaired and the command retried once.

The harness stubs dpkg, dpkg-query and the wrapped command, and points
DPKG_ADMINDIR at a scratch tree, so no scenario touches the real package database.
"""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

_HARNESS_SOURCE = Path(__file__).parent / "run_dpkg_heal_test.sh"
_HARNESS_DEST = "skyhook_dir/steps/run_dpkg_heal_test.sh"


def _run_scenario(scenario: str) -> int:
    """Run one harness scenario; return its exit code (0 = behaved as specified)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="steps/run_dpkg_heal_test.sh",
            configmaps={},
            env_vars={"SCENARIO": scenario},
            extra_files=[(_HARNESS_SOURCE, _HARNESS_DEST)],
        )
        return result.exit_code
    finally:
        runner.cleanup()


# --- dpkg_needs_configure ---


@pytest.mark.parametrize(
    "scenario",
    [
        # A numerically-named journal file in <admindir>/updates/ is apt's own
        # trigger (debSystem::CheckUpdates).
        "needs_configure_journal",
        # Packages parked in half-configured need a repair even with no journal.
        "needs_configure_half_configured",
        # A clean database must not report as interrupted.
        "needs_configure_clean",
        # Unrelated leftovers in updates/ are not journal files.
        "needs_configure_ignores_non_journal",
    ],
)
def test_dpkg_needs_configure(scenario):
    assert _run_scenario(scenario) == 0


# --- apt_with_dpkg_heal ---


def test_heal_is_a_noop_on_success():
    """A succeeding command must not be repaired or retried."""
    assert _run_scenario("heal_noop_on_success") == 0


def test_heal_recovers_apt_update():
    """The reported failure: apt-get update refused because dpkg was interrupted."""
    assert _run_scenario("heal_recovers_apt_update") == 0


def test_heal_recovers_apt_install_preserving_arguments():
    """The retry must re-run the original command, arguments intact."""
    assert _run_scenario("heal_recovers_apt_install") == 0


def test_heal_propagates_unrelated_failure():
    """A failure with a healthy dpkg must keep its exit code and not be retried."""
    assert _run_scenario("heal_propagates_unrelated_failure") == 0


# --- dpkg_repair: stale DKMS tree entries ---
#
# A DKMS package whose postinst aborts with "Error! DKMS tree already contains:
# <module>-<version>" fails identically on every retry, so `dpkg --configure -a`
# alone leaves the package half-configured forever and every later apt command
# dies on it. Observed on efa 3.0.0.


def test_repair_removes_stale_dkms_module():
    """The efa failure: the stale tree entry is dropped, then configure succeeds."""
    assert _run_scenario("repair_removes_stale_dkms_module") == 0


def test_repair_handles_hyphenated_module_name():
    """<module>-<version> cannot be split on the last hyphen; nvidia-peermem-1.2.3 proves it."""
    assert _run_scenario("repair_handles_hyphenated_module_name") == 0


def test_repair_propagates_unresolvable_dkms_conflict():
    """A conflict with no matching dkms status entry must surface, not loop."""
    assert _run_scenario("repair_propagates_unresolvable_dkms") == 0


def test_repair_propagates_non_dkms_configure_failure():
    """A configure failure that is not a DKMS conflict must propagate untouched."""
    assert _run_scenario("repair_propagates_non_dkms_configure_failure") == 0
