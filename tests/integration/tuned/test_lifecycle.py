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
Tests for the tuned package install and uninstall lifecycle.

Each test runs the real install_tuned.sh against the distribution's package
manager inside a container, so it exercises the per-distribution branch of the
script. systemctl is replaced by the nvidia_tuned suite's test double, because
containers have no systemd.
"""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

TESTS_DIR = Path(__file__).resolve().parent
STEP_ROOT = "/skyhook-package/skyhook_dir"
EXTRA_FILES = [
    (TESTS_DIR.parent / "nvidia_tuned" / "fakes" / "systemctl", "test-bin/systemctl"),
    (TESTS_DIR / "fakes" / "zypper", "test-bin/zypper"),
]
ENV = {
    "PATH": "/skyhook-package/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}


def start(base_image, script, env=None):
    """Start a container, run the first lifecycle script, and return (runner, exit code, output)."""
    runner = DockerTestRunner(package="tuned", base_image=base_image)
    result = runner.run_script(
        script=script,
        env_vars={**ENV, **(env or {})},
        extra_files=EXTRA_FILES,
    )
    return runner, result.exit_code, result.stdout


def step(runner, script, env=None):
    """Run a further lifecycle script in the same container and return (exit code, output)."""
    result = runner.container.exec_run(
        ["/bin/bash", f"{STEP_ROOT}/{script}"],
        workdir="/",
        environment={**ENV, **(env or {})},
    )
    return result.exit_code, result.output.decode(errors="replace")


def sh(runner, command):
    """Run a shell command in the container and return its exit code."""
    return runner.container.exec_run(
        ["/bin/bash", "-c", command], workdir="/", environment=ENV
    ).exit_code


def require_zypper(base_image):
    if "suse" not in base_image:
        pytest.skip("zypper exit-code handling only applies to SUSE images")


def test_install_and_uninstall(base_image):
    """install_tuned.sh installs tuned with the distro's package manager; uninstall removes it."""
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        assert sh(runner, "command -v tuned && command -v tuned-adm") == 0, out

        code, out = step(runner, "install_tuned_check.sh")
        assert code == 0, out

        code, out = step(runner, "uninstall_tuned.sh")
        assert code == 0, out

        code, out = step(runner, "uninstall_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


def test_install_is_idempotent(base_image):
    """Running install_tuned.sh twice succeeds and leaves tuned installed."""
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, f"attempt 1: {out}"
        code, out = step(runner, "install_tuned.sh")
        assert code == 0, f"attempt 2: {out}"

        code, out = step(runner, "install_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


def test_uninstall_is_idempotent(base_image):
    """Running uninstall_tuned.sh again after tuned is gone is a no-op, as the agent re-runs uninstall."""
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        for attempt in (1, 2):
            code, out = step(runner, "uninstall_tuned.sh")
            assert code == 0, f"attempt {attempt}: {out}"

        code, out = step(runner, "uninstall_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


def test_uninstall_without_tuned(base_image):
    """uninstall_tuned.sh succeeds on a node where tuned was never installed."""
    runner, code, out = start(base_image, "uninstall_tuned.sh")
    try:
        assert code == 0, out
        assert sh(runner, "command -v tuned") != 0, "base image must not ship tuned"

        code, out = step(runner, "uninstall_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


@pytest.mark.parametrize("zypper_exit", ["106", "107"])
def test_install_accepts_zypper_informational_exit(base_image, zypper_exit):
    """zypper exit codes 106 and 107 are accepted when tuned did get installed."""
    require_zypper(base_image)
    runner, code, out = start(
        base_image, "install_tuned.sh", {"FAKE_ZYPPER_EXIT": zypper_exit}
    )
    try:
        assert code == 0, out
        assert "WARN: zypper exited" in out, out

        code, out = step(runner, "install_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


def test_install_fails_when_zypper_did_not_install_tuned(base_image):
    """An informational exit code does not hide a failed install: rpm must confirm tuned."""
    require_zypper(base_image)
    runner, code, out = start(
        base_image,
        "install_tuned.sh",
        {"FAKE_ZYPPER_EXIT": "106", "FAKE_ZYPPER_SKIP_REAL": "1"},
    )
    try:
        assert code == 106, out
    finally:
        runner.cleanup()


@pytest.mark.parametrize("zypper_exit", ["106", "107"])
def test_uninstall_accepts_zypper_informational_exit(base_image, zypper_exit):
    """zypper exit codes 106 and 107 on remove are accepted when tuned did get removed."""
    require_zypper(base_image)
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        code, out = step(runner, "uninstall_tuned.sh", {"FAKE_ZYPPER_EXIT": zypper_exit})
        assert code == 0, out
        assert "WARN: zypper exited" in out, out

        code, out = step(runner, "uninstall_tuned_check.sh")
        assert code == 0, out
    finally:
        runner.cleanup()


def test_uninstall_fails_when_zypper_did_not_remove_tuned(base_image):
    """An informational exit code does not hide a failed removal: rpm must confirm tuned is gone."""
    require_zypper(base_image)
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        code, out = step(
            runner,
            "uninstall_tuned.sh",
            {"FAKE_ZYPPER_EXIT": "106", "FAKE_ZYPPER_SKIP_REAL": "1"},
        )
        assert code == 106, out
    finally:
        runner.cleanup()
