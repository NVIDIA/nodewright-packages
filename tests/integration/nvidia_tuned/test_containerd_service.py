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
Tests for containerd_service.sh, the tuned [script] that raises the container runtime's
stack limit through a systemd drop-in.

Covers:
- which runtime units get the drop-in: containerd.service on kubeadm-style hosts, and the
  rke2/k3s service units whose embedded containerd serves workloads (regression for
  NVIDIA/nodewright-packages#134, where only an inactive containerd.service was tuned)
  and K3s units named by the installer (k3s-<name>.service from INSTALL_K3S_NAME)
- verify: the drop-in text and the limit systemd resolves for each installed unit
- stop: the drop-in survives the soft stop tuned issues at shutdown, so the runtime has
  it on the next boot, and is removed on full_rollback

The script is byte-identical in every profile that carries it; that is asserted here so
the copies cannot drift. Real systemctl is replaced by the test double in fakes/, where
an installed.<unit> marker makes a unit loaded and daemon-reload snapshots its drop-ins.
"""

import shutil
import tempfile
import time
from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner

BASE_IMAGE = "ubuntu:24.04"

FAKES_DIR = Path(__file__).resolve().parent / "fakes"
FAKE_BIN = "/fakes"
OUTPUT_FILE = "/tmp/step-output"
STATE = "/tmp/fake-systemctl"

PROFILE_COPIES = [
    "profiles/os/common/nvidia-gb200-performance/containerd_service.sh",
    "profiles/os/ubuntu/26.04/nvidia-vr200-performance/containerd_service.sh",
    "profiles/os/ubuntu/26.04/nvidia-vr200-noreboot-base/containerd_service.sh",
]
SCRIPT = f"/skyhook-package/{PROFILE_COPIES[0]}"

RUNTIME_UNITS = [
    "containerd.service",
    "rke2-server.service",
    "rke2-agent.service",
    "k3s.service",
    "k3s-agent.service",
]
LIMIT_LINE = "LimitSTACK=67108864"

ENV = {
    "PATH": f"{FAKE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "FAKE_SYSTEMCTL_STATE": STATE,
}


@pytest.fixture
def node():
    """A running container with the package mounted and the fakes ahead of PATH."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=BASE_IMAGE)
    temp_dir = Path(tempfile.mkdtemp(prefix="skyhook-test-"))
    runner.temp_dir = str(temp_dir)

    package_dir = temp_dir / "skyhook-package"
    shutil.copytree(runner._package_path, package_dir, dirs_exist_ok=True)
    for sh_file in package_dir.rglob("*.sh"):
        sh_file.chmod(0o755)

    fakes_dir = temp_dir / "fakes"
    shutil.copytree(FAKES_DIR, fakes_dir)
    for fake in fakes_dir.iterdir():
        fake.chmod(0o755)

    try:
        runner.container = runner.client.containers.run(
            BASE_IMAGE,
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
    probe = f"test -x {SCRIPT} && test -x /fakes/systemctl"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if runner.container.exec_run(["/bin/bash", "-c", probe]).exit_code == 0:
                return
        except Exception:  # container is not accepting execs yet
            pass
        time.sleep(0.25)
    raise RuntimeError("container never became ready")


# ---------------------------------------------------------------------------
# Container helpers. Every assertion resolves to an exit code.
# ---------------------------------------------------------------------------


def sh(node: DockerTestRunner, command: str) -> int:
    """Run a shell command in the container and return its exit code."""
    return node.container.exec_run(
        ["/bin/bash", "-c", command], workdir="/", environment=ENV
    ).exit_code


def run(node: DockerTestRunner, *args: str) -> int:
    """Run the script with tuned's arguments, saving its output to OUTPUT_FILE."""
    return sh(node, f"{SCRIPT} {' '.join(args)} > {OUTPUT_FILE} 2>&1")


def said(node: DockerTestRunner, text: str) -> bool:
    """True when the last run's output contained text."""
    return sh(node, f"grep -qF {shell_quote(text)} {OUTPUT_FILE}") == 0


def output(node: DockerTestRunner) -> str:
    """Best-effort read of the last run's output, for assertion messages only."""
    result = node.container.exec_run(["cat", OUTPUT_FILE])
    return result.output.decode("utf-8", errors="replace")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def dropin(unit: str) -> str:
    return f"/etc/systemd/system/{unit}.d/containerd.conf"


def has_dropin(node: DockerTestRunner, unit: str) -> bool:
    return sh(node, f"grep -qxF {LIMIT_LINE} {dropin(unit)}") == 0


def install(node: DockerTestRunner, *units: str):
    """Mark units as installed, so systemctl reports them loaded."""
    assert sh(node, f"mkdir -p {STATE} && cd {STATE} && touch "
              + " ".join(f"installed.{u}" for u in units)) == 0


def write_dropin(node: DockerTestRunner, unit: str, name: str, line: str):
    path = f"/etc/systemd/system/{unit}.d/{name}"
    assert sh(node, f"mkdir -p $(dirname {path}) && printf '[Service]\\n%s\\n' "
              f"{shell_quote(line)} > {path}") == 0


def daemon_reload(node: DockerTestRunner):
    assert sh(node, "systemctl daemon-reload") == 0


# ---------------------------------------------------------------------------
# Profile copies
# ---------------------------------------------------------------------------


def test_every_profile_carries_the_same_script(node):
    first = f"/skyhook-package/{PROFILE_COPIES[0]}"
    for copy in PROFILE_COPIES[1:]:
        assert sh(node, f"cmp -s {first} /skyhook-package/{copy}") == 0, copy


# ---------------------------------------------------------------------------
# start: which units get the drop-in
# ---------------------------------------------------------------------------


def test_start_targets_containerd_service_on_a_kubeadm_host(node):
    install(node, "containerd.service")
    assert run(node, "start") == 0, output(node)
    assert has_dropin(node, "containerd.service")
    for unit in RUNTIME_UNITS[1:]:
        assert sh(node, f"test -e {dropin(unit)}") != 0, unit


def test_start_falls_back_to_containerd_service_when_no_runtime_unit_is_installed(node):
    assert run(node, "start") == 0, output(node)
    assert has_dropin(node, "containerd.service")


@pytest.mark.parametrize(
    "units",
    [
        ["rke2-server.service", "rke2-agent.service"],
        ["containerd.service", "rke2-server.service", "rke2-agent.service"],
        ["k3s.service"],
        ["k3s-agent.service"],
    ],
    ids=["rke2", "rke2-with-inactive-distro-containerd", "k3s-server", "k3s-agent"],
)
def test_start_targets_every_installed_runtime_unit(node, units):
    """Issue #134: RKE2's embedded containerd runs under rke2-server/rke2-agent."""
    install(node, *units)
    assert run(node, "start") == 0, output(node)
    for unit in RUNTIME_UNITS:
        assert has_dropin(node, unit) == (unit in units), unit


def test_start_targets_an_installer_named_k3s_unit(node):
    """K3s installed with INSTALL_K3S_NAME=edge runs as k3s-edge.service."""
    install(node, "containerd.service", "k3s-edge.service")
    assert run(node, "start") == 0, output(node)
    assert has_dropin(node, "k3s-edge.service")


def test_start_does_not_depend_on_the_runtime_being_active(node):
    """tuned applies the profile at boot, before rke2-server is active."""
    install(node, "containerd.service", "rke2-server.service")
    assert sh(node, f"test ! -e {STATE}/active.rke2-server.service") == 0
    assert run(node, "start") == 0, output(node)
    assert has_dropin(node, "rke2-server.service")


def test_start_reloads_systemd(node):
    install(node, "rke2-server.service")
    assert run(node, "start") == 0, output(node)
    assert sh(node, f"grep -qx 'daemon-reload ' {STATE}/calls") == 0


def test_start_is_idempotent(node):
    install(node, "rke2-server.service")
    assert run(node, "start") == 0, output(node)
    assert run(node, "start") == 0, output(node)
    assert sh(node, f"test $(grep -c . {dropin('rke2-server.service')}) -eq 2") == 0


# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------


def test_verify_passes_after_start(node):
    install(node, "containerd.service", "rke2-server.service", "rke2-agent.service")
    assert run(node, "start") == 0, output(node)
    assert run(node, "verify") == 0, output(node)


def test_verify_rejects_an_inert_containerd_dropin_on_rke2(node):
    """The #134 false positive: the distro unit is tuned, the RKE2 runtime is not."""
    install(node, "containerd.service", "rke2-server.service")
    write_dropin(node, "containerd.service", "containerd.conf", LIMIT_LINE)
    daemon_reload(node)
    assert run(node, "verify") != 0
    assert said(node, "rke2-server.service"), output(node)


def test_verify_checks_an_installer_named_k3s_unit(node):
    install(node, "k3s-edge.service")
    assert run(node, "start") == 0, output(node)
    assert sh(node, f"rm {dropin('k3s-edge.service')}") == 0
    assert run(node, "verify") != 0
    assert said(node, "k3s-edge.service"), output(node)


def test_verify_ignore_missing_accepts_absent_dropins(node):
    install(node, "rke2-server.service")
    assert run(node, "verify", "ignore_missing") == 0, output(node)


def test_verify_rejects_a_dropin_without_the_limit(node):
    install(node, "rke2-server.service")
    write_dropin(node, "rke2-server.service", "containerd.conf", "LimitSTACK=8388608")
    daemon_reload(node)
    assert run(node, "verify") != 0
    assert said(node, "does not set"), output(node)


def test_verify_rejects_a_dropin_shadowed_by_a_later_one(node):
    install(node, "rke2-server.service")
    assert run(node, "start") == 0, output(node)
    write_dropin(node, "rke2-server.service", "zz-override.conf", "LimitSTACK=8388608")
    daemon_reload(node)
    assert run(node, "verify") != 0
    assert said(node, "systemd resolves LimitSTACK=8388608"), output(node)


def test_verify_rejects_a_dropin_systemd_has_not_loaded(node):
    install(node, "rke2-server.service")
    write_dropin(node, "rke2-server.service", "containerd.conf", LIMIT_LINE)
    assert run(node, "verify") != 0
    assert said(node, "systemd resolves LimitSTACK=infinity"), output(node)


# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------


def test_soft_stop_keeps_the_dropin_for_the_next_boot(node):
    """tuned omits full_rollback only at shutdown; the runtime starts before tuned."""
    install(node, "containerd.service", "rke2-server.service", "rke2-agent.service")
    assert run(node, "start") == 0, output(node)
    assert run(node, "stop") == 0, output(node)
    for unit in ["containerd.service", "rke2-server.service", "rke2-agent.service"]:
        assert has_dropin(node, unit), unit


def test_full_rollback_removes_every_dropin(node):
    install(node, "containerd.service", "rke2-server.service", "rke2-agent.service")
    assert run(node, "start") == 0, output(node)
    assert run(node, "stop", "full_rollback") == 0, output(node)
    for unit in RUNTIME_UNITS:
        assert sh(node, f"test ! -e /etc/systemd/system/{unit}.d") == 0, unit


def test_full_rollback_removes_a_dropin_left_on_a_unit_no_longer_installed(node):
    write_dropin(node, "k3s.service", "containerd.conf", LIMIT_LINE)
    assert run(node, "stop", "full_rollback") == 0, output(node)
    assert sh(node, "test ! -e /etc/systemd/system/k3s.service.d") == 0


def test_full_rollback_removes_the_dropin_of_an_installer_named_k3s_unit(node):
    write_dropin(node, "k3s-edge.service", "containerd.conf", LIMIT_LINE)
    assert run(node, "stop", "full_rollback") == 0, output(node)
    assert sh(node, "test ! -e /etc/systemd/system/k3s-edge.service.d") == 0


def test_full_rollback_keeps_other_dropins_and_their_directory(node):
    install(node, "rke2-server.service")
    assert run(node, "start") == 0, output(node)
    write_dropin(node, "rke2-server.service", "10-site.conf", "LimitNOFILE=1048576")
    assert run(node, "stop", "full_rollback") == 0, output(node)
    assert sh(node, f"test ! -e {dropin('rke2-server.service')}") == 0
    assert sh(node, "test -f /etc/systemd/system/rke2-server.service.d/10-site.conf") == 0


def test_unknown_command_fails(node):
    assert run(node, "bogus") != 0
    assert said(node, "Usage:"), output(node)
