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
script. systemctl is replaced by the test double in fakes/, because containers
have no systemd.
"""

import shutil
import tempfile
import time
from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

FAKES_DIR = Path(__file__).resolve().parent / "fakes"
FAKE_BIN = "/fakes"
STEP_ROOT = "/skyhook-package/skyhook_dir"

ENV = {
    "PATH": f"{FAKE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "SKYHOOK_DIR": "/skyhook-package",
    "STEP_ROOT": STEP_ROOT,
}


@pytest.fixture
def node(base_image):
    """A running container with the package mounted and the fakes ahead of PATH."""
    runner = DockerTestRunner(package="tuned", base_image=base_image)
    temp_dir = Path(tempfile.mkdtemp(prefix="skyhook-test-"))
    runner.temp_dir = str(temp_dir)

    package_dir = temp_dir / "skyhook-package"
    shutil.copytree(runner._package_path, package_dir, dirs_exist_ok=True)
    for sh_file in package_dir.rglob("*.sh"):
        sh_file.chmod(0o755)
    (package_dir / "configmaps").mkdir(exist_ok=True)

    fakes_dir = temp_dir / "fakes"
    shutil.copytree(FAKES_DIR, fakes_dir)
    for fake in fakes_dir.iterdir():
        fake.chmod(0o755)

    try:
        runner.container = runner.client.containers.run(
            runner.base_image,
            command=["/bin/bash", "-c", "tail -f /dev/null"],
            detach=True,
            volumes={
                str(package_dir): {"bind": "/skyhook-package", "mode": "rw"},
                str(fakes_dir): {"bind": FAKE_BIN, "mode": "ro"},
            },
            remove=False,
            tty=False,
            stdin_open=False,
        )
        _wait_until_ready(runner)
        yield runner
    finally:
        runner.cleanup()


def _wait_until_ready(runner: DockerTestRunner, timeout: float = 60.0):
    """Block until the container accepts execs and both bind mounts are visible."""
    probe = f"test -x {STEP_ROOT}/install_tuned.sh && test -x {FAKE_BIN}/systemctl"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if runner.container.exec_run(["/bin/bash", "-c", probe]).exit_code == 0:
                return
        except Exception:  # container is not accepting execs yet
            pass
        time.sleep(0.25)
    raise RuntimeError("container never became ready")


def step(node: DockerTestRunner, script: str):
    """Run a lifecycle script and return (exit code, combined output)."""
    result = node.container.exec_run(
        ["/bin/bash", f"{STEP_ROOT}/{script}"], workdir="/", environment=ENV
    )
    return result.exit_code, result.output.decode(errors="replace")


def sh(node: DockerTestRunner, command: str) -> int:
    """Run a shell command in the container and return its exit code."""
    return node.container.exec_run(
        ["/bin/bash", "-c", command], workdir="/", environment=ENV
    ).exit_code


def test_install_and_uninstall(node, base_image):
    """install_tuned.sh installs tuned with the distro's package manager; uninstall removes it."""
    assert sh(node, "command -v tuned") != 0, "base image must not ship tuned"

    code, out = step(node, "install_tuned.sh")
    assert code == 0, out
    assert sh(node, "command -v tuned && command -v tuned-adm") == 0, out

    code, out = step(node, "install_tuned_check.sh")
    assert code == 0, out

    code, out = step(node, "uninstall_tuned.sh")
    assert code == 0, out

    code, out = step(node, "uninstall_tuned_check.sh")
    assert code == 0, out


def test_install_is_idempotent(node, base_image):
    """Running install_tuned.sh twice succeeds and leaves tuned installed."""
    for attempt in (1, 2):
        code, out = step(node, "install_tuned.sh")
        assert code == 0, f"attempt {attempt}: {out}"

    code, out = step(node, "install_tuned_check.sh")
    assert code == 0, out
