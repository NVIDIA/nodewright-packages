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

import time
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


def require_apt(base_image):
    if not base_image.startswith(("ubuntu", "debian")):
        pytest.skip("apt lock waiting only applies to apt-based images")


# Holds one of apt's locks with an fcntl lock, the kind apt and dpkg take, and creates
# LOCK_HELD once it has the lock.
LOCK_HELD = "/tmp/lock-held"
LOCK_HOLDER = (
    "python3 -c 'import fcntl, os, sys, time; "
    "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o640); "
    "fcntl.lockf(fd, fcntl.LOCK_EX); open(sys.argv[3], \"w\").close(); "
    "time.sleep(float(sys.argv[2]))' {lock} {seconds} " + LOCK_HELD
)


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


RETRIED = "found an apt or dpkg lock held by another process"


def hold_lock(runner, lock, seconds):
    """Hold <lock> for <seconds> in the background, returning once the holder has it."""
    assert sh(runner, "apt-get install -y -qq python3-minimal >/dev/null 2>&1") == 0
    runner.container.exec_run(
        ["/bin/bash", "-c", LOCK_HOLDER.format(lock=lock, seconds=seconds)], detach=True
    )
    held = f"for _ in $(seq 100); do [ -e {LOCK_HELD} ] && exit 0; sleep 0.1; done; exit 1"
    assert sh(runner, held) == 0, f"the lock holder did not take {lock} within 10s"


@pytest.mark.parametrize(
    "lock",
    [
        # Taken by `apt update`; apt has no wait for it, so the run is retried.
        "/var/lib/apt/lists/lock",
        # Taken by `apt install`; apt waits for it itself, given DPkg::Lock::Timeout.
        "/var/lib/dpkg/lock-frontend",
    ],
)
def test_install_waits_for_a_held_apt_lock(base_image, lock):
    """A lock another process holds (apt-daily, nvidia-setup's apply) is waited out, not a failure."""
    require_apt(base_image)
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        hold_lock(runner, lock, 15)
        started = time.monotonic()
        code, out = step(runner, "install_tuned.sh", {"APT_LOCK_RETRY_INTERVAL_SECONDS": "2"})
        waited = time.monotonic() - started
        assert code == 0, out
        assert waited >= 10, f"finished in {waited:.0f}s, before the lock was released:\n{out}"
        if lock.endswith("lists/lock"):
            assert RETRIED in out, out
        else:
            # `apt install` takes the dpkg lock even with nothing to install, so succeeding
            # means it got the lock after the holder let go. With no retry logged, apt waited
            # for it itself. (apt 2.8 also prints "Waiting for cache lock"; apt 2.6 does not
            # without a terminal, so that line is not asserted.)
            assert RETRIED not in out, f"apt did not wait for the dpkg lock itself:\n{out}"
    finally:
        runner.cleanup()


def test_apt_lock_retry_stops_waiting_when_the_budget_is_spent(base_image):
    """APT_LOCK_WAIT_SECONDS bounds apt's own wait for the dpkg lock.

    `apt` carries its own 120s default (Binary::apt::DPkg::Lock::Timeout), which outranks
    APT_CONFIG and apt.conf.d; only -o on the command line overrides it. The helper is called
    directly so the time measured is the `apt install` alone, without install_tuned.sh's
    network-bound `apt update` before it.
    """
    require_apt(base_image)
    runner, code, out = start(base_image, "install_tuned.sh")
    try:
        assert code == 0, out
        hold_lock(runner, "/var/lib/dpkg/lock-frontend", 60)
        started = time.monotonic()
        result = runner.container.exec_run(
            ["/bin/bash", "-c", f"source {STEP_ROOT}/utils.sh && apt_lock_retry apt install -y tuned"],
            workdir="/",
            environment={**ENV, "APT_LOCK_WAIT_SECONDS": "4", "APT_LOCK_RETRY_INTERVAL_SECONDS": "2"},
        )
        waited = time.monotonic() - started
        out = result.output.decode(errors="replace")

        assert result.exit_code != 0, f"waited out a 60s lock on a 4s budget:\n{out}"
        assert "Unable to acquire the dpkg frontend lock" in out, out
        assert waited < 15, f"gave up after {waited:.0f}s on a 4s budget:\n{out}"
    finally:
        runner.cleanup()


def test_install_rejects_a_malformed_lock_wait(base_image):
    """APT_LOCK_WAIT_SECONDS that is not whole seconds fails the step and says why."""
    require_apt(base_image)
    runner, code, out = start(base_image, "install_tuned.sh", {"APT_LOCK_WAIT_SECONDS": "10m"})
    try:
        assert code != 0, out
        assert "APT_LOCK_WAIT_SECONDS must be whole seconds from 0 to 999999, got '10m'" in out, out
    finally:
        runner.cleanup()
