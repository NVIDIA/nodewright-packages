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
Tests for the DOCA Spectrum-X congestion control steps.

The feature is gated twice: on bundled assets for the service/accelerator pair, and on
the `spcx_cc` configmap key, which defaults to on. The most important behaviour is that
switching it off never requires the DOCA binary, so a node that opted out does not need
the dependency installed.

Real systemctl, journalctl, udevadm, and the DOCA daemon are replaced by doubles in
fakes/. `pgrep` is the container's own, so the foreign-process guard is exercised
against a genuinely running process rather than a stub.

Assertions resolve to exit codes; see test_host_setup.py for why.
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

UNIT_DEST = "/etc/systemd/system/doca-spcx-cc@.service"
RULES_DEST = "/etc/udev/rules.d/99-doca-spcx-cc.rules"
BUNDLED_DIR = "/skyhook-package/profiles/service/oci/spcx-cc-gb300"
DOCA_BIN = f"{FAKE_BIN}/doca_spcx_cc"
IB_DIR = "/tmp/infiniband"

STEP_ENV = {
    "SKYHOOK_DIR": "/skyhook-package",
    "STEP_ROOT": "/skyhook-package/skyhook_dir",
    "PATH": f"{FAKE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "FAKE_SYSTEMCTL_STATE": "/tmp/fake-systemctl",
    "FAKE_UDEV_STATE": "/tmp/fake-udev",
    "DOCA_SPCX_CC_BIN": DOCA_BIN,
    "IB_CLASS_DIR": IB_DIR,
    "READY_TIMEOUT_SECS": "6",
    "READY_POLL_SECS": "1",
}

OCI_GB300 = {"accelerator": "gb300", "service": "oci"}
OTHER_SHAPES = [
    {"accelerator": "h100", "service": "eks"},
    {"accelerator": "gb200", "service": "oci"},
    {"accelerator": "gb300"},
]
OTHER_SHAPE_IDS = ["eks-h100", "oci-gb200", "gb300-no-service"]


@pytest.fixture
def node():
    runner = DockerTestRunner(package="nvidia-tuned", base_image=BASE_IMAGE)
    temp_dir = Path(tempfile.mkdtemp(prefix="skyhook-test-"))
    runner.temp_dir = str(temp_dir)

    package_dir = temp_dir / "skyhook-package"
    shutil.copytree(runner._package_path, package_dir, dirs_exist_ok=True)
    for sh_file in package_dir.rglob("*.sh"):
        sh_file.chmod(0o755)
    (package_dir / "configmaps").mkdir(parents=True, exist_ok=True)
    (package_dir / "node-metadata").mkdir(parents=True, exist_ok=True)

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
    probe = "test -f /skyhook-package/config.json && test -x /fakes/systemctl"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if runner.container.exec_run(["/bin/bash", "-c", probe]).exit_code == 0:
                return
        except Exception:
            pass
        time.sleep(0.25)
    raise RuntimeError("container never became ready")


def sh(node: DockerTestRunner, command: str, env: dict = None) -> int:
    return node.container.exec_run(
        ["/bin/bash", "-c", command], workdir="/", environment=env or {}
    ).exit_code


def step(node: DockerTestRunner, script: str, env: dict = None) -> int:
    step_env = dict(STEP_ENV)
    if env:
        step_env.update(env)
    return node.container.exec_run(
        ["/bin/bash", "-c", f"/skyhook-package/skyhook_dir/{script} > {OUTPUT_FILE} 2>&1"],
        workdir="/skyhook-package",
        environment=step_env,
    ).exit_code


def quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def said(node: DockerTestRunner, text: str) -> bool:
    return sh(node, f"grep -qF {quote(text)} {OUTPUT_FILE}") == 0


def output(node: DockerTestRunner) -> str:
    return node.container.exec_run(["cat", OUTPUT_FILE]).output.decode(
        "utf-8", errors="replace"
    )


def exists(node: DockerTestRunner, path: str) -> bool:
    return sh(node, f"test -e {path}") == 0


def configure(node: DockerTestRunner, **configmaps):
    cmds = ["rm -rf /skyhook-package/configmaps", "mkdir -p /skyhook-package/configmaps"]
    for key, value in configmaps.items():
        cmds.append(f"printf '%s' {quote(value)} > /skyhook-package/configmaps/{key}")
    assert sh(node, " && ".join(cmds)) == 0


def start_foreign_daemon(node: DockerTestRunner, rail: str, device_arg: str = "-d {}"):
    """Start a process indistinguishable from a real foreign doca_spcx_cc.

    The guard matches on `pgrep -x`, which compares /proc/pid/comm. comm follows the
    executable, so a shell-script double is reported as `bash` and would not be found.
    Copying an ELF binary gives the right comm, and `exec -a` supplies a cmdline in the
    real daemon's shape so the rail can be parsed out of it. `device_arg` is how the
    rail is passed, `-d {}` as OCA 1.64 does.
    """
    # Copied once: a second cp over the binary while a daemon runs it fails (ETXTBSY).
    assert sh(node, "test -x /usr/local/bin/doca_spcx_cc || cp /usr/bin/sleep /usr/local/bin/doca_spcx_cc") == 0
    # argv0 travels via the environment so it does not have to survive nested quoting.
    assert (
        sh(
            node,
            "setsid nohup bash -c 'exec -a \"$FOREIGN_ARGV0\" "
            "/usr/local/bin/doca_spcx_cc 3600' >/dev/null 2>&1 < /dev/null & sleep 1",
            env={"FOREIGN_ARGV0": f"doca_spcx_cc {device_arg.format(rail)} -w -1"},
        )
        == 0
    )


FAKE_PROC = "/tmp/proc"


def own_foreign_daemons(
    node: DockerTestRunner,
    unit: str,
    transient: bool = False,
    main: bool = True,
    exec_start: str = "",
    only: str = "",
):
    """Attribute running doca_spcx_cc processes to a systemd unit, the way OCA 1.64 runs it.

    The container has no systemd, so the cgroup the scripts read is faked under
    FAKE_PROC (passed as PROC_DIR) and the unit is marked active in the systemctl fake.
    `unit` takes the process's rail via %s, so each rail gets its own instance. `main`
    records the process as the unit's main process; `exec_start` sets the command the
    unit reports. `only` limits this to processes whose rail starts with it, so a
    second call can attribute a different set.
    """
    cmds = [f"mkdir -p {FAKE_PROC} /tmp/fake-systemctl"]
    cmds.append(
        "for pid in $(pgrep -x doca_spcx_cc); do "
        "rail=$(tr '\\0' ' ' < /proc/$pid/cmdline | sed -En 's/(^|.* )(-d|--device)[= ]([^ ]+).*/\\3/p'); "
        f"case \"$rail\" in {quote(only)}*) ;; *) continue ;; esac; "
        + (f"u=$(printf {quote(unit)} \"$rail\"); " if "%s" in unit else f"u={quote(unit)}; ")
        + f"mkdir -p {FAKE_PROC}/$pid; "
        f"cp /proc/$pid/cmdline {FAKE_PROC}/$pid/cmdline; "
        f"echo \"0::/system.slice/system-doca_spcx_cc.slice/$u\" > {FAKE_PROC}/$pid/cgroup; "
        "touch /tmp/fake-systemctl/active.$u; "
        + ("touch /tmp/fake-systemctl/transient.$u; " if transient else "")
        + ("echo $pid > /tmp/fake-systemctl/mainpid.$u; " if main else "")
        + (f"echo {quote(exec_start)} > /tmp/fake-systemctl/execstart.$u; " if exec_start else "")
        + "done"
    )
    assert sh(node, " && ".join(cmds)) == 0


def stage_rails(node: DockerTestRunner, count: int = 4):
    """Fake /sys/class/infiniband matching what a real GB300 node presents.

    Bonded PFs have no physfn; the host's own mlx5_0..3 are VFs and do have one.
    """
    cmds = [f"rm -rf {IB_DIR} /tmp/pci", f"mkdir -p {IB_DIR} /tmp/pci"]
    for i in range(count):
        # `device` is a symlink to the PCI node on a real host; the script resolves it
        # to a BDF for the firmware query.
        bdf = f"{i:04d}:03:00.0"
        cmds.append(f"mkdir -p /tmp/pci/{bdf}")
        cmds.append(f"mkdir -p {IB_DIR}/mlx5_bond_{i}")
        cmds.append(f"ln -sfn /tmp/pci/{bdf} {IB_DIR}/mlx5_bond_{i}/device")
    # Host VFs: same shape as the real node, physfn present.
    for i in range(4):
        cmds.append(f"mkdir -p {IB_DIR}/mlx5_{i}/device/physfn")
    assert sh(node, " && ".join(cmds)) == 0


# ---------------------------------------------------------------------------
# Gating
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("configmaps", OTHER_SHAPES, ids=OTHER_SHAPE_IDS)
def test_spcx_cc_is_a_noop_for_other_shapes(node, configmaps):
    configure(node, **configmaps)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert said(node, "nothing to do"), output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)

    assert step(node, "configure_spcx_cc_check.sh") == 0, output(node)
    assert said(node, "nothing to verify"), output(node)


# ---------------------------------------------------------------------------
# Switched off: must never require DOCA
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["off", "OFF", "false", "0", "no"])
def test_spcx_cc_off_does_not_require_doca(node, value):
    """A node that opted out must not need the dependency installed."""
    configure(node, spcx_cc=value, **OCI_GB300)
    stage_rails(node)

    # No DOCA binary anywhere on PATH.
    rc = step(node, "configure_spcx_cc.sh", {"DOCA_SPCX_CC_BIN": "/nonexistent/doca_spcx_cc"})
    assert rc == 0, output(node)
    assert said(node, "switched off"), output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)

    rc = step(
        node, "configure_spcx_cc_check.sh", {"DOCA_SPCX_CC_BIN": "/nonexistent/doca_spcx_cc"}
    )
    assert rc == 0, output(node)
    assert said(node, "is off"), output(node)


def test_spcx_cc_off_tears_down_a_previously_enabled_node(node):
    """Flipping the key off must stop the units, not merely skip."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert exists(node, UNIT_DEST)
    assert exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service")

    configure(node, spcx_cc="off", **OCI_GB300)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service")
    assert step(node, "configure_spcx_cc_check.sh") == 0, output(node)


# ---------------------------------------------------------------------------
# Switched on
# ---------------------------------------------------------------------------


def test_spcx_cc_defaults_to_on_when_the_key_is_absent(node):
    configure(node, **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert said(node, "running on 4 rail(s)"), output(node)


def test_spcx_cc_on_installs_unit_and_rule_and_starts_each_rail(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert sh(node, f"cmp -s {BUNDLED_DIR}/doca-spcx-cc@.service {UNIT_DEST}") == 0
    assert sh(node, f"cmp -s {BUNDLED_DIR}/99-doca-spcx-cc.rules {RULES_DEST}") == 0

    for i in range(4):
        unit = f"doca-spcx-cc@mlx5_bond_{i}.service"
        assert exists(node, f"/tmp/fake-systemctl/enabled.{unit}"), f"{unit} not enabled"
        assert exists(node, f"/tmp/fake-systemctl/active.{unit}"), f"{unit} not started"

    # The VF device must not have been targeted.
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_0.service")
    assert sh(node, "grep -q 'control' /tmp/fake-udev/calls") == 0


def test_spcx_cc_on_fails_clearly_when_doca_is_missing(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    rc = step(node, "configure_spcx_cc.sh", {"DOCA_SPCX_CC_BIN": "/nonexistent/doca_spcx_cc"})
    assert rc != 0
    assert said(node, "cannot be started"), output(node)
    assert said(node, "not present or not executable"), output(node)
    assert said(node, 'spcx_cc: "off"'), output(node)
    assert not exists(node, UNIT_DEST), "must not install a unit it cannot run"


def test_spcx_cc_is_idempotent(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert step(node, "configure_spcx_cc_check.sh") == 0, output(node)


def test_spcx_cc_fails_loudly_when_no_bonded_pfs_are_found(node):
    """The bond naming is an assumption; if it does not hold, say so rather than no-op.

    Bonded PFs are created by the mlx5 driver at load, so a node that has any has them
    before this runs. Finding none means the device naming is not what is expected, and
    the diagnostic has to show what is actually present.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node, count=0)

    assert step(node, "configure_spcx_cc.sh") != 0
    assert said(node, "no mlx5_bond_* devices found"), output(node)
    # The non-bond device staged by stage_rails must be listed so the operator can see
    # what the node actually presents.
    assert said(node, "mlx5_0"), output(node)
    assert said(node, "RAIL_GLOB"), output(node)


def test_spcx_cc_rail_glob_is_overridable(node):
    """Escape hatch for a node whose RDMA devices were renamed."""
    configure(node, spcx_cc="on", **OCI_GB300)
    cmds = [
        f"rm -rf {IB_DIR}",
        f"mkdir -p {IB_DIR}/rdma_rail0/device {IB_DIR}/rdma_rail1/device",
        f"mkdir -p {IB_DIR}/mlx5_0/device/physfn",
    ]
    assert sh(node, " && ".join(cmds)) == 0

    assert step(node, "configure_spcx_cc.sh", {"RAIL_GLOB": "rdma_rail*"}) == 0, output(node)
    assert said(node, "running on 2 rail(s)"), output(node)
    assert exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@rdma_rail0.service")
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_0.service")


def test_spcx_cc_never_targets_a_virtual_function(node):
    """A rename can leave a VF matching a pattern meant for PFs; physfn is the guard."""
    configure(node, spcx_cc="on", **OCI_GB300)
    cmds = [
        f"rm -rf {IB_DIR}",
        # Renamed devices where one is really a VF.
        f"mkdir -p {IB_DIR}/rdma_rail0/device",
        f"mkdir -p {IB_DIR}/rdma_rail1/device/physfn",
    ]
    assert sh(node, " && ".join(cmds)) == 0

    assert step(node, "configure_spcx_cc.sh", {"RAIL_GLOB": "rdma_rail*"}) == 0, output(node)
    assert said(node, "running on 1 rail(s)"), output(node)
    assert said(node, "rdma_rail1: it is a virtual function"), output(node)
    assert exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@rdma_rail0.service")
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@rdma_rail1.service")

    # The check must apply the same exclusion. Without it, it would demand an active
    # unit for the VF that configure deliberately never started.
    rc = step(node, "configure_spcx_cc_check.sh", {"RAIL_GLOB": "rdma_rail*"})
    assert rc == 0, output(node)


def test_spcx_cc_ignores_host_vfs_with_a_broad_glob(node):
    """Even mlx5_* must not start congestion control on the host's own VFs."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh", {"RAIL_GLOB": "mlx5_*"}) == 0, output(node)
    for i in range(4):
        assert not exists(node, f"/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_{i}.service")
        assert exists(node, f"/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_{i}.service")


# ---------------------------------------------------------------------------
# Foreign process guard
# ---------------------------------------------------------------------------


def test_spcx_cc_refuses_when_another_owner_is_already_running(node):
    """Two owners would give a rail two processes; the tool requires exactly one."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    start_foreign_daemon(node, "mlx5_bond_0")

    rc = step(node, "configure_spcx_cc.sh")
    assert rc != 0
    assert said(node, "already running outside this package"), output(node)
    assert said(node, "mlx5_bond_0"), output(node)
    assert not exists(node, UNIT_DEST), "must not install while a foreign owner runs"


def test_spcx_cc_foreign_guard_reports_discovered_state_not_assumed_names(node):
    """The remedy must not name units invented elsewhere; report what was found."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    start_foreign_daemon(node, "mlx5_bond_2")

    assert step(node, "configure_spcx_cc.sh") != 0
    assert said(node, "rail mlx5_bond_2"), output(node)
    # No systemd in the test container, so the owner is reported as absent rather than guessed.
    assert said(node, "<no systemd unit>"), output(node)
    assert not said(node, "doca-spcx-cc-rail0"), output(node)


def oca_rails(node: DockerTestRunner):
    """The device names OCA 1.64 leaves on GB300: bonds renamed to rdma_railN and host
    VFs to rdma_vf_railN, so the default mlx5_bond_* glob finds nothing.

    The front-end NICs stay mlx5_8 and mlx5_17. They are PFs, but not rails, and nothing
    runs congestion control on them.
    """
    cmds = [f"rm -rf {IB_DIR}", f"mkdir -p {IB_DIR}"]
    cmds += [f"mkdir -p {IB_DIR}/rdma_rail{i}" for i in range(4)]
    cmds += [f"mkdir -p {IB_DIR}/rdma_vf_rail{i}/device/physfn" for i in range(4)]
    cmds += [f"mkdir -p {IB_DIR}/mlx5_8/device {IB_DIR}/mlx5_17/device"]
    assert sh(node, " && ".join(cmds)) == 0


OCA_UNIT = "doca_spcx_cc@%s.service"
OWN_UNIT = "doca-spcx-cc@%s.service"


def start_oca(node: DockerTestRunner, rails=range(4), device_arg: str = "-d {}", **kwargs):
    """Run OCA 1.64's congestion control on the given rdma_railN rails."""
    for i in rails:
        start_foreign_daemon(node, f"rdma_rail{i}", device_arg)
    own_foreign_daemons(node, OCA_UNIT, only="rdma_rail", **kwargs)


def test_spcx_cc_defers_to_persistent_units_run_elsewhere(node):
    """OCA 1.64 runs PCC itself from persistent units; the package steps aside."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    assert said(node, "Deferring to them"), output(node)
    assert said(node, "doca_spcx_cc@rdma_rail3.service"), output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)

    assert step(node, "configure_spcx_cc_check.sh", env) == 0, output(node)
    assert said(node, "run outside this package"), output(node)


def test_spcx_cc_deferring_removes_units_this_package_installed(node):
    """A node that ran this package's units hands over without leaving a second owner."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert exists(node, UNIT_DEST)

    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)
    assert step(node, "configure_spcx_cc_check.sh", env) == 0, output(node)


def test_spcx_cc_still_refuses_transient_units(node):
    """`systemd-run` units vanish on reboot, so they are not an owner to defer to."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    start_foreign_daemon(node, "mlx5_bond_0")
    own_foreign_daemons(node, "run-%s.service", transient=True)

    assert step(node, "configure_spcx_cc.sh", {"PROC_DIR": FAKE_PROC}) != 0
    assert said(node, "already running outside this package"), output(node)
    assert said(node, "owner run-mlx5_bond_0.service"), output(node)
    assert not exists(node, UNIT_DEST)


def test_spcx_cc_does_not_defer_while_a_sibling_owner_unit_is_down(node):
    """Three live owners and one failed instance would leave a rail uncovered."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node, rails=range(3))
    assert sh(node, "touch /tmp/fake-systemctl/failed.doca_spcx_cc@rdma_rail3.service") == 0
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "rdma_rail3 has no congestion control process outside this package"), output(node)
    assert not exists(node, UNIT_DEST)

    # The check names the outside owner rather than this package's missing template.
    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "rdma_rail3 has no congestion control process outside this package"), output(node)
    assert said(node, "cannot defer to them"), output(node)
    assert not said(node, "unit template missing"), output(node)


def test_spcx_cc_does_not_defer_while_an_owner_instance_is_inactive(node):
    """Every instance of the owner's template must be up, not just one per device."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node)
    assert sh(node, "touch /tmp/fake-systemctl/failed.doca_spcx_cc@rdma_rail9.service") == 0
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "doca_spcx_cc@rdma_rail9.service is not active"), output(node)
    assert not exists(node, UNIT_DEST)


def test_spcx_cc_does_not_defer_when_a_rail_has_no_owner_instance(node):
    """An instance systemd never loaded is invisible to list-units; check the devices."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node, rails=range(3))
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "rdma_rail3 has no congestion control process outside this package"), output(node)
    assert not exists(node, UNIT_DEST)


def test_spcx_cc_does_not_defer_when_the_node_has_no_rails(node):
    """With no rail to check, one outside unit must not be enough to hand over.

    Here the PFs are mlx5_0..3, which match no rail name, and a persistent unit runs on
    mlx5_0 alone. Handing over would leave mlx5_1..3 without congestion control.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    cmds = [f"rm -rf {IB_DIR}"] + [f"mkdir -p {IB_DIR}/mlx5_{i}/device" for i in range(4)]
    assert sh(node, " && ".join(cmds)) == 0
    start_foreign_daemon(node, "mlx5_0")
    own_foreign_daemons(node, OCA_UNIT)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "Not deferring: no rails"), output(node)
    assert not said(node, "Deferring to them"), output(node)
    assert not exists(node, UNIT_DEST)

    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "cannot defer to them"), output(node)


def test_spcx_cc_does_not_defer_when_a_rail_has_two_owners(node):
    """The tool wants one process per rail, so a second persistent owner on a rail is refused."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node)
    # A second persistent unit on rdma_rail0. own_foreign_daemons would also re-attribute
    # OCA's rdma_rail0 process, so only the newest process is given to the other unit.
    start_foreign_daemon(node, "rdma_rail0")
    assert (
        sh(
            node,
            "pid=$(pgrep -nx doca_spcx_cc) && u=other-pcc.service && "
            f"mkdir -p {FAKE_PROC}/$pid && cp /proc/$pid/cmdline {FAKE_PROC}/$pid/cmdline && "
            f"echo \"0::/system.slice/$u\" > {FAKE_PROC}/$pid/cgroup && "
            "touch /tmp/fake-systemctl/active.$u && echo $pid > /tmp/fake-systemctl/mainpid.$u",
        )
        == 0
    )
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "rdma_rail0 has more than one congestion control process outside this package"), output(node)
    assert not said(node, "Deferring to them"), output(node)
    assert not exists(node, UNIT_DEST)

    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "cannot defer to them"), output(node)


def test_spcx_cc_refuses_a_stray_process_in_an_unrelated_unit(node):
    """A process left behind by a script in a long-lived unit is not a persistent owner.

    cloud-final.service stays active after its script ends, but nothing restarts a
    process it left behind after a reboot.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    for i in range(4):
        start_foreign_daemon(node, f"rdma_rail{i}")
    own_foreign_daemons(node, "cloud-final.service", main=False)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) != 0
    assert said(node, "already running outside this package"), output(node)
    assert said(node, "owner cloud-final.service"), output(node)


def test_spcx_cc_defers_to_a_unit_whose_command_runs_the_tool(node):
    """A unit that runs doca_spcx_cc through a wrapper still owns it."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(
        node,
        main=False,
        exec_start="/usr/bin/env /opt/mellanox/doca/tools/doca_spcx_cc -d rdma_rail0 -w -1",
    )
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    assert said(node, "Deferring to them"), output(node)


@pytest.mark.parametrize("device_arg", ["-d={}", "--device {}", "--device={}"])
def test_spcx_cc_reads_the_rail_from_any_device_argument_form(node, device_arg):
    """OCA 1.64 passes `-d rdma_railN`; the other spellings must still map to a rail."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node, device_arg=device_arg)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    assert said(node, "Deferring to them"), output(node)


def test_spcx_cc_hands_over_while_this_packages_units_still_run(node):
    """A 0.10.0 node whose units are still running when OCA 1.64 starts its own.

    Both sets of processes are present; the package must stop its own rather than
    refuse, since OCA already covers every rail.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    for i in range(4):
        start_foreign_daemon(node, f"mlx5_bond_{i}")
    own_foreign_daemons(node, OWN_UNIT, only="mlx5_bond")

    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}

    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    assert said(node, "Deferring to them"), output(node)
    assert not exists(node, UNIT_DEST)
    for i in range(4):
        assert not exists(node, f"/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_{i}.service")

    assert step(node, "configure_spcx_cc_check.sh", env) == 0, output(node)
    assert said(node, "run outside this package"), output(node)


def test_spcx_cc_deferred_check_ignores_not_found_stubs(node):
    """After handing over, the old instances linger as not-found stubs until reboot.

    The device units udev created keep `Wants=` on them, as for uninstall. Counting the
    stubs left a node that had handed over unable to pass the check.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}
    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    for i in range(4):
        assert sh(node, f"touch /tmp/fake-systemctl/stub.doca-spcx-cc@mlx5_bond_{i}.service") == 0

    assert step(node, "configure_spcx_cc_check.sh", env) == 0, output(node)
    assert said(node, "run outside this package"), output(node)

    # A unit of this package's that is still loaded remains a failure.
    assert sh(node, "touch /tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service") == 0
    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "still loaded"), output(node)


def test_spcx_cc_off_check_ignores_not_found_stubs(node):
    """Switching off after running leaves the same stubs, and must pass too."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    configure(node, spcx_cc="off", **OCI_GB300)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert sh(node, "touch /tmp/fake-systemctl/stub.doca-spcx-cc@mlx5_bond_0.service") == 0

    assert step(node, "configure_spcx_cc_check.sh") == 0, output(node)
    assert said(node, "is off"), output(node)


def test_spcx_cc_deferred_check_fails_when_an_owner_never_reports_ready(node):
    """Deferring is only right while the other owner actually has PCC engaged."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}
    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)

    env["FAKE_JOURNAL_NEVER_READY"] = "1"
    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "did not report"), output(node)


def test_spcx_cc_deferred_check_ignores_readiness_from_an_earlier_run(node):
    """A persistent journal keeps old readiness lines; only the current run counts."""
    configure(node, spcx_cc="on", **OCI_GB300)
    oca_rails(node)
    start_oca(node)
    env = {"PROC_DIR": FAKE_PROC}
    assert step(node, "configure_spcx_cc.sh", env) == 0, output(node)
    for i in range(4):
        assert sh(node, f"touch /tmp/fake-systemctl/stale.doca_spcx_cc@rdma_rail{i}.service") == 0

    env["FAKE_JOURNAL_NEVER_READY"] = "1"
    assert step(node, "configure_spcx_cc_check.sh", env) != 0
    assert said(node, "did not report"), output(node)


# ---------------------------------------------------------------------------
# Check behaviour
# ---------------------------------------------------------------------------


def test_spcx_cc_check_fails_when_a_rail_never_reports_ready(node):
    """Unit active is not the same as PCC engaged."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    rc = step(node, "configure_spcx_cc_check.sh", {"FAKE_JOURNAL_NEVER_READY": "1"})
    assert rc != 0
    assert said(node, "did not report"), output(node)


def test_spcx_cc_check_fails_when_the_unit_is_missing(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc_check.sh") != 0
    assert said(node, "unit template missing"), output(node)


# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------


def test_spcx_cc_uninstall_removes_unit_and_rule(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    assert step(node, "uninstall_spcx_cc.sh") == 0, output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, RULES_DEST)
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service")
    assert step(node, "uninstall_spcx_cc_check.sh") == 0, output(node)


def test_spcx_cc_uninstall_is_a_noop_when_never_installed(node):
    configure(node, **OCI_GB300)

    assert step(node, "uninstall_spcx_cc.sh") == 0, output(node)
    assert said(node, "nothing to stop"), output(node)
    assert step(node, "uninstall_spcx_cc_check.sh") == 0, output(node)


def test_spcx_cc_uninstall_does_not_need_doca(node):
    """Teardown must work on a node where DOCA was removed or never installed."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)

    rc = step(node, "uninstall_spcx_cc.sh", {"DOCA_SPCX_CC_BIN": "/nonexistent/doca_spcx_cc"})
    assert rc == 0, output(node)
    assert step(node, "uninstall_spcx_cc_check.sh") == 0, output(node)


# ---------------------------------------------------------------------------
# Firmware prerequisite
# ---------------------------------------------------------------------------


def test_spcx_cc_reports_firmware_state_when_enabled(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert said(node, "USER_PROGRAMMABLE_CC=True(1)"), output(node)
    # The unenforced knobs are still surfaced for diagnostics.
    assert said(node, "PCC_INT_EN=False(0)"), output(node)
    assert said(node, "ROCE_ADAPTIVE_ROUTING_EN=True(1)"), output(node)


def test_spcx_cc_fails_when_user_programmable_cc_is_disabled(node):
    """Firmware that disallows a programmable algorithm is a missing dependency."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    rc = step(node, "configure_spcx_cc.sh", {"FAKE_USER_PROGRAMMABLE_CC": "False(0)"})
    assert rc != 0
    assert said(node, "USER_PROGRAMMABLE_CC is False(0), need True(1)"), output(node)
    assert said(node, "would run without doing anything useful"), output(node)
    assert said(node, 'spcx_cc: "off"'), output(node)
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service")
    # Nothing may be written to the host until every prerequisite has cleared: a udev
    # rule left behind would still instantiate units on the next device event.
    assert not exists(node, UNIT_DEST), "must not install a unit it cannot run"
    assert not exists(node, RULES_DEST), "must not leave a rule that could start it later"


def test_spcx_cc_fails_when_only_one_rail_has_bad_firmware(node):
    """A partially configured node must not come up half enabled."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    rc = step(node, "configure_spcx_cc.sh", {"FAKE_MLXCONFIG_DEVICE_FAIL": "0002:03:00.0"})
    assert rc != 0
    assert said(node, "mlx5_bond_2 (0002:03:00.0)"), output(node)
    assert not exists(node, "/tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service")


def test_spcx_cc_fails_when_mlxconfig_is_absent(node):
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)

    rc = step(node, "configure_spcx_cc.sh", {"MLXCONFIG_BIN": "mlxconfig_absent"})
    assert rc != 0
    assert said(node, "prerequisites cannot be checked"), output(node)
    assert said(node, "firmware tools"), output(node)


def test_spcx_cc_off_ignores_firmware_entirely(node):
    """Disabled feature must not care about any dependency, firmware included."""
    configure(node, spcx_cc="off", **OCI_GB300)
    stage_rails(node)

    rc = step(
        node,
        "configure_spcx_cc.sh",
        {
            "MLXCONFIG_BIN": "mlxconfig_absent",
            "DOCA_SPCX_CC_BIN": "/nonexistent/doca_spcx_cc",
            "FAKE_USER_PROGRAMMABLE_CC": "False(0)",
        },
    )
    assert rc == 0, output(node)
    assert said(node, "switched off"), output(node)


def test_spcx_cc_off_tolerates_processes_owned_by_something_else(node):
    """Off means this package takes no part, not that nothing else may run PCC.

    Found on a real node: a hand-started daemon made the off-state check fail, which
    contradicts the contract that a disabled feature cannot fail the package.
    """
    configure(node, spcx_cc="off", **OCI_GB300)
    stage_rails(node)
    start_foreign_daemon(node, "mlx5_bond_0")

    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert step(node, "configure_spcx_cc_check.sh") == 0, output(node)
    assert said(node, "is off"), output(node)
    assert said(node, "running from outside this package"), output(node)


def test_spcx_cc_uninstall_check_ignores_not_found_stubs(node):
    """A successful uninstall leaves not-found stubs, and they must not fail the check.

    Removing the template unit file is what makes each instance not-found, and systemd
    keeps them enumerated under `--all` until they are garbage collected. The device
    units udev created still reference them, so they survive daemon-reload, and
    reset-failed does not clear them because they are inactive/dead rather than failed.
    Counting them made the check unpassable on a node that had actually been cleaned up,
    which blocked every nvidia-tuned upgrade.
    """
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert step(node, "uninstall_spcx_cc.sh") == 0, output(node)

    # What the node looks like afterwards: unit file and rule gone, stubs still listed.
    for rail in ("mlx5_bond_0", "mlx5_bond_1"):
        unit = f"doca-spcx-cc@{rail}.service"
        assert sh(node, f"touch /tmp/fake-systemctl/stub.{unit}") == 0

    assert step(node, "uninstall_spcx_cc_check.sh") == 0, output(node)
    assert said(node, "units are removed"), output(node)


def test_spcx_cc_uninstall_check_still_fails_on_a_loaded_unit(node):
    """Ignoring not-found must not weaken the assertion for a unit that is still loaded."""
    configure(node, spcx_cc="on", **OCI_GB300)
    stage_rails(node)
    assert step(node, "configure_spcx_cc.sh") == 0, output(node)
    assert step(node, "uninstall_spcx_cc.sh") == 0, output(node)

    # A still-loaded instance is a real uninstall failure, stub or not.
    assert sh(node, "touch /tmp/fake-systemctl/active.doca-spcx-cc@mlx5_bond_0.service") == 0
    assert sh(node, "touch /tmp/fake-systemctl/stub.doca-spcx-cc@mlx5_bond_1.service") == 0

    assert step(node, "uninstall_spcx_cc_check.sh") != 0, output(node)
    assert said(node, "still known to systemd"), output(node)
    assert said(node, "doca-spcx-cc@mlx5_bond_0.service"), output(node)
