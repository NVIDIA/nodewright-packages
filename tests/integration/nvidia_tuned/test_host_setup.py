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
Tests for the nvidia-tuned host setup steps added for OCI GB300.

Covers:
- install_rdma_vfs_ready.sh, its config, post-interrupt, and uninstall checks
- configure_pcie_acs.sh, its config and post-interrupt checks
- configure_iommu_passthrough.sh, its config and post-interrupt checks
- the bundled wait-rdma-vfs.sh helper

Both steps self-gate on bundled assets resolved from the service and accelerator
configmaps, so the no-op path for every other service/accelerator pair is covered too.

These steps do not depend on the OS, so they run against a single base image rather
than the package TEST_MATRIX. Real systemctl, rdma_topo, update-grub, and uname are
replaced by the test doubles in fakes/.

Assertions go through exit codes rather than captured text: a step's output is written
to a file in the container and matched there with grep. The container exec API returns
exit codes reliably but its streamed output is occasionally empty for a short-lived
exec under parallel load, which otherwise shows up as a flaky text assertion.
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

UNIT_DEST = "/etc/systemd/system/rdma-vfs-ready.service"
HELPER_DEST = "/usr/local/sbin/wait-rdma-vfs.sh"
ACS_DROPIN = "/etc/default/grub.d/config-acs.cfg"
IOMMU_DROPIN = "/etc/default/grub.d/99-iommu-passthrough.cfg"
FAKE_CMDLINE = "/tmp/fake-cmdline"
FAKE_IOMMU_GROUPS = "/tmp/fake-iommu-groups"

# Either side of the 6.11 threshold, where arm-smmu-v3 gained S1DSS_BYPASS.
OLD_KERNEL = "6.8.0-1060-generic"
NEW_KERNEL = "6.14.0-1015-generic"
SYSTEMCTL_CALLS = "/tmp/fake-systemctl/calls"

BUNDLED_DIR = "/skyhook-package/profiles/service/oci/rdma-vfs-ready-gb300"
BUNDLED_UNIT = f"{BUNDLED_DIR}/rdma-vfs-ready.service"
BUNDLED_HELPER = f"{BUNDLED_DIR}/wait-rdma-vfs.sh"

STEP_ENV = {
    "SKYHOOK_DIR": "/skyhook-package",
    "STEP_ROOT": "/skyhook-package/skyhook_dir",
    "PATH": f"{FAKE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "FAKE_SYSTEMCTL_STATE": "/tmp/fake-systemctl",
    "FAKE_RDMA_TOPO_STATE": "/tmp/fake-rdma-topo",
    "FAKE_GRUB_STATE": "/tmp/fake-grub",
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
    (package_dir / "configmaps").mkdir(parents=True, exist_ok=True)
    (package_dir / "node-metadata").mkdir(parents=True, exist_ok=True)

    fakes_dir = temp_dir / "fakes"
    shutil.copytree(FAKES_DIR, fakes_dir)
    for fake in fakes_dir.iterdir():
        fake.chmod(0o755)

    # The guard opens before container creation, not after: if containers.run raises,
    # the temp dir would otherwise leak, and if readiness times out the container would.
    # runner.cleanup() tolerates a container that was never assigned.
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
    probe = "test -f /skyhook-package/config.json && test -x /fakes/systemctl"
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


def sh(node: DockerTestRunner, command: str, env: dict = None) -> int:
    """Run a shell command in the container and return its exit code."""
    return node.container.exec_run(
        ["/bin/bash", "-c", command], workdir="/", environment=env or {}
    ).exit_code


def step(node: DockerTestRunner, script: str, env: dict = None) -> int:
    """Run a lifecycle step, tee its output to OUTPUT_FILE, and return its exit code."""
    step_env = dict(STEP_ENV)
    if env:
        step_env.update(env)
    return node.container.exec_run(
        [
            "/bin/bash",
            "-c",
            f"/skyhook-package/skyhook_dir/{script} > {OUTPUT_FILE} 2>&1",
        ],
        workdir="/skyhook-package",
        environment=step_env,
    ).exit_code


def said(node: DockerTestRunner, text: str) -> bool:
    """True when the last step's output contained text."""
    return sh(node, f"grep -qF {shell_quote(text)} {OUTPUT_FILE}") == 0


def output(node: DockerTestRunner) -> str:
    """Best-effort read of the last step's output, for assertion messages only."""
    result = node.container.exec_run(["cat", OUTPUT_FILE])
    return result.output.decode("utf-8", errors="replace")


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def exists(node: DockerTestRunner, path: str) -> bool:
    return sh(node, f"test -e {path}") == 0


def contains(node: DockerTestRunner, path: str, text: str) -> bool:
    return sh(node, f"grep -qF {shell_quote(text)} {path}") == 0


def same(node: DockerTestRunner, left: str, right: str) -> bool:
    return sh(node, f"cmp -s {left} {right}") == 0


def configure(node: DockerTestRunner, **configmaps):
    """Replace the container's configmaps."""
    cmds = ["rm -rf /skyhook-package/configmaps", "mkdir -p /skyhook-package/configmaps"]
    for key, value in configmaps.items():
        cmds.append(
            f"printf '%s' {shell_quote(value)} > /skyhook-package/configmaps/{key}"
        )
    assert sh(node, " && ".join(cmds)) == 0


OCI_GB300 = {"accelerator": "gb300", "service": "oci"}
OTHER_SHAPES = [
    {"accelerator": "h100", "service": "eks"},
    {"accelerator": "gb200", "service": "oci"},
    {"accelerator": "gb300"},
]
OTHER_SHAPE_IDS = ["eks-h100", "oci-gb200", "gb300-no-service"]


# ---------------------------------------------------------------------------
# install_rdma_vfs_ready.sh
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "configmaps",
    OTHER_SHAPES + [{"accelerator": "gb300", "service": ""}],
    ids=OTHER_SHAPE_IDS + ["gb300-empty-service"],
)
def test_rdma_vfs_ready_is_a_noop_without_bundled_assets(node, configmaps):
    """Only service/accelerator pairs that ship the unit get it installed."""
    configure(node, **configmaps)

    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)
    assert said(node, "nothing to do"), output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, HELPER_DEST)

    assert step(node, "install_rdma_vfs_ready_check.sh") == 0, output(node)
    assert said(node, "nothing to verify"), output(node)

    assert step(node, "post_interrupt_rdma_vfs_ready_check.sh") == 0, output(node)
    assert said(node, "nothing to verify"), output(node)


def test_rdma_vfs_ready_installs_and_enables_for_oci_gb300(node):
    configure(node, **OCI_GB300)

    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)
    assert same(node, BUNDLED_UNIT, UNIT_DEST)
    assert same(node, BUNDLED_HELPER, HELPER_DEST)
    assert sh(node, f"test -x {HELPER_DEST}") == 0
    assert contains(node, SYSTEMCTL_CALLS, "daemon-reload")
    assert contains(node, SYSTEMCTL_CALLS, "enable rdma-vfs-ready.service")

    # Enabled but not started: the unit is a boot-ordering gate.
    assert not exists(node, "/tmp/fake-systemctl/active.rdma-vfs-ready.service")

    assert step(node, "install_rdma_vfs_ready_check.sh") == 0, output(node)
    assert said(node, "installed and enabled"), output(node)


def test_rdma_vfs_ready_unit_orders_before_kubelet(node):
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    for line in (
        "Before=kubelet.service",
        "After=snap.oracle-cloud-agent.oracle-cloud-agent.service",
        "Type=oneshot",
        "RemainAfterExit=true",
        f"ExecStart={HELPER_DEST}",
    ):
        assert contains(node, UNIT_DEST, line), f"missing {line!r} in unit"


def test_rdma_vfs_ready_install_is_idempotent(node):
    configure(node, **OCI_GB300)

    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)
    assert step(node, "install_rdma_vfs_ready_check.sh") == 0, output(node)


def test_rdma_vfs_ready_check_fails_when_unit_missing(node):
    configure(node, **OCI_GB300)

    assert step(node, "install_rdma_vfs_ready_check.sh") != 0
    assert said(node, "missing"), output(node)


def test_rdma_vfs_ready_check_fails_when_unit_edited_on_host(node):
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)
    assert sh(node, f"echo '# drift' >> {UNIT_DEST}") == 0

    assert step(node, "install_rdma_vfs_ready_check.sh") != 0
    assert said(node, "does not match bundled"), output(node)


def test_rdma_vfs_ready_post_interrupt_check_requires_the_unit_to_have_run(node):
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    # Enabled but never started, which is what a missed boot looks like.
    assert step(node, "post_interrupt_rdma_vfs_ready_check.sh") != 0
    assert said(node, "did not run during boot"), output(node)

    # Simulate the unit running during the post-reboot boot.
    assert sh(node, "touch /tmp/fake-systemctl/active.rdma-vfs-ready.service") == 0
    assert step(node, "post_interrupt_rdma_vfs_ready_check.sh") == 0, output(node)
    assert said(node, "ran during boot"), output(node)


def test_rdma_vfs_ready_uninstall_removes_the_gate(node):
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    assert step(node, "uninstall_rdma_vfs_ready.sh") == 0, output(node)
    assert not exists(node, UNIT_DEST)
    assert not exists(node, HELPER_DEST)
    assert contains(node, SYSTEMCTL_CALLS, "disable rdma-vfs-ready.service")
    assert step(node, "uninstall_rdma_vfs_ready_check.sh") == 0, output(node)


def test_rdma_vfs_ready_uninstall_runs_regardless_of_configmaps(node):
    """Uninstall keys on host state, so it cleans up after changed configmaps too."""
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    configure(node, accelerator="h100", service="eks")
    assert step(node, "uninstall_rdma_vfs_ready.sh") == 0, output(node)
    assert not exists(node, UNIT_DEST)
    assert step(node, "uninstall_rdma_vfs_ready_check.sh") == 0, output(node)


def test_rdma_vfs_ready_uninstall_is_idempotent_when_never_installed(node):
    configure(node, **OCI_GB300)

    assert step(node, "uninstall_rdma_vfs_ready.sh") == 0, output(node)
    assert step(node, "uninstall_rdma_vfs_ready.sh") == 0, output(node)
    assert step(node, "uninstall_rdma_vfs_ready_check.sh") == 0, output(node)


def test_rdma_vfs_ready_uninstall_cleans_up_a_partial_install(node):
    """A missing unit file must not short-circuit the disable; the symlink can outlive it."""
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    # Unit file gone but still enabled, which is what a half-torn-down host looks like.
    assert sh(node, f"rm -f {UNIT_DEST}") == 0
    assert exists(node, "/tmp/fake-systemctl/enabled.rdma-vfs-ready.service")

    assert step(node, "uninstall_rdma_vfs_ready.sh") == 0, output(node)
    assert not exists(node, "/tmp/fake-systemctl/enabled.rdma-vfs-ready.service")
    assert not exists(node, HELPER_DEST)
    assert step(node, "uninstall_rdma_vfs_ready_check.sh") == 0, output(node)


def test_rdma_vfs_ready_uninstall_check_fails_while_the_unit_remains(node):
    configure(node, **OCI_GB300)
    assert step(node, "install_rdma_vfs_ready.sh") == 0, output(node)

    assert step(node, "uninstall_rdma_vfs_ready_check.sh") != 0
    assert said(node, "still present"), output(node)


# ---------------------------------------------------------------------------
# wait-rdma-vfs.sh
# ---------------------------------------------------------------------------


def stage_netdevs(node: DockerTestRunner, vfs: int, plain: int = 2):
    """Build a fake /sys/class/net tree with `vfs` VFs and `plain` non-VF devices."""
    cmds = ["rm -rf /tmp/netdevs", "mkdir -p /tmp/netdevs"]
    for i in range(plain):
        cmds.append(f"mkdir -p /tmp/netdevs/eth{i}/device")
    for i in range(vfs):
        # A VF netdev is identified by a physfn link back to its physical function.
        cmds.append(f"mkdir -p /tmp/netdevs/rdma{i}/device")
        cmds.append(f"ln -sfn /tmp/netdevs/eth0/device /tmp/netdevs/rdma{i}/device/physfn")
    assert sh(node, " && ".join(cmds)) == 0


def wait_helper(node: DockerTestRunner, **env) -> int:
    helper_env = {"SYS_CLASS_NET": "/tmp/netdevs", "POLL_INTERVAL_SECS": "1"}
    helper_env.update({k: str(v) for k, v in env.items()})
    return sh(node, f"{BUNDLED_HELPER} > {OUTPUT_FILE} 2>&1", env=helper_env)


def test_wait_rdma_vfs_returns_once_all_vfs_are_present(node):
    stage_netdevs(node, vfs=4)

    assert wait_helper(node, EXPECTED_VFS=4, TIMEOUT_SECS=10) == 0, output(node)
    assert said(node, "Found 4 RDMA VFs"), output(node)


def test_wait_rdma_vfs_releases_early_when_a_partial_count_settles(node):
    """A dead CX8 leaves fewer VFs than expected; the node must still join."""
    stage_netdevs(node, vfs=3)

    rc = wait_helper(node, EXPECTED_VFS=4, TIMEOUT_SECS=60, STABLE_POLLS=3)
    assert rc == 0, output(node)
    assert said(node, "settled at 3"), output(node)


def test_wait_rdma_vfs_exits_zero_when_no_vfs_ever_appear(node):
    """The helper must never block a node from joining the cluster."""
    stage_netdevs(node, vfs=0)

    assert wait_helper(node, EXPECTED_VFS=4, TIMEOUT_SECS=4) == 0, output(node)
    assert said(node, "Timed out"), output(node)


def test_wait_rdma_vfs_ignores_non_vf_interfaces(node):
    """Only netdevs with a physfn link count as VFs."""
    stage_netdevs(node, vfs=0, plain=6)

    assert wait_helper(node, EXPECTED_VFS=1, TIMEOUT_SECS=4) == 0, output(node)
    assert said(node, "with 0 RDMA VFs"), output(node)


def test_wait_rdma_vfs_aborts_on_error_but_still_releases_kubelet(node):
    """errexit must reach inside main, and an abort must still exit 0.

    Bash suppresses errexit throughout a function invoked as a condition, so calling
    main via `if ! main` would let it run past a failed command instead of aborting.
    Pointing SYS_CLASS_NET at a path that cannot be globbed makes count_vfs fail.
    """
    stage_netdevs(node, vfs=0)
    assert sh(node, "rm -rf /tmp/netdevs") == 0

    # A non-existent tree makes the glob literal, so the physfn test fails on a path
    # containing '*', and the run aborts rather than polling to the timeout.
    rc = wait_helper(
        node, SYS_CLASS_NET="/tmp/does-not-exist", EXPECTED_VFS=4, TIMEOUT_SECS=4
    )
    assert rc == 0, output(node)


def test_wait_rdma_vfs_falls_back_on_a_bad_poll_interval(node):
    """POLL_INTERVAL_SECS=0 would stop elapsed advancing and busy-spin until systemd."""
    stage_netdevs(node, vfs=0)

    rc = wait_helper(node, EXPECTED_VFS=4, TIMEOUT_SECS=4, POLL_INTERVAL_SECS=0)
    assert rc == 0, output(node)
    assert said(node, "POLL_INTERVAL_SECS='0' is not a positive integer"), output(node)


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("EXPECTED_VFS", "abc"),
        ("TIMEOUT_SECS", "-5"),
        ("STABLE_POLLS", "0"),
        ("POLL_INTERVAL_SECS", "1.5"),
    ],
)
def test_wait_rdma_vfs_rejects_non_positive_integer_overrides(node, name, value):
    """Non-numeric, negative, zero, and fractional overrides all fall back to defaults.

    An empty value is deliberately not covered: `${VAR:-default}` already substitutes
    the default for an empty string, so it never reaches the validator.
    """
    stage_netdevs(node, vfs=4)

    rc = wait_helper(node, **{"EXPECTED_VFS": "4", "TIMEOUT_SECS": "6", name: value})
    assert rc == 0, output(node)
    assert said(node, f"{name}='{value}' is not a positive integer"), output(node)


# ---------------------------------------------------------------------------
# configure_pcie_acs.sh
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("configmaps", OTHER_SHAPES, ids=OTHER_SHAPE_IDS)
def test_pcie_acs_is_a_noop_without_the_opt_in_marker(node, configmaps):
    configure(node, **configmaps)

    assert step(node, "configure_pcie_acs.sh") == 0, output(node)
    assert said(node, "nothing to do"), output(node)
    assert not exists(node, ACS_DROPIN)
    assert not exists(node, "/tmp/fake-rdma-topo/calls")

    for check in ("configure_pcie_acs_check.sh", "post_interrupt_pcie_acs_check.sh"):
        assert step(node, check) == 0, output(node)
        assert said(node, "nothing to verify"), output(node)


def test_pcie_acs_does_nothing_when_the_node_is_already_correct(node):
    configure(node, **OCI_GB300)
    passing = {"FAKE_RDMA_TOPO_CHECK": "pass"}

    assert step(node, "configure_pcie_acs.sh", passing) == 0, output(node)
    assert said(node, "already correct"), output(node)
    assert not exists(node, ACS_DROPIN)

    assert step(node, "configure_pcie_acs_check.sh", passing) == 0, output(node)
    assert said(node, "values are correct"), output(node)


def test_pcie_acs_writes_the_bootloader_dropin_when_check_fails(node):
    configure(node, **OCI_GB300)

    assert step(node, "configure_pcie_acs.sh", {"FAKE_RDMA_TOPO_CHECK": "fail"}) == 0
    assert said(node, "reboot is required"), output(node)
    assert contains(node, ACS_DROPIN, "config_acs")
    assert contains(node, "/tmp/fake-rdma-topo/calls", "write-grub-acs")
    assert exists(node, "/tmp/fake-grub/update-grub-ran")


def test_pcie_acs_config_check_accepts_a_pending_reboot(node):
    """Before the reboot, rdma_topo check still fails; the drop-in is the evidence."""
    configure(node, **OCI_GB300)
    failing = {"FAKE_RDMA_TOPO_CHECK": "fail"}

    assert step(node, "configure_pcie_acs.sh", failing) == 0, output(node)
    assert step(node, "configure_pcie_acs_check.sh", failing) == 0, output(node)
    assert said(node, "pending reboot"), output(node)


@pytest.mark.parametrize(
    ("dropin", "accepted"),
    [
        ('GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT pci=config_acs=1@0008:00:00.0"', True),
        ("pci=config_acs=1@0008:00:00.0", True),
        ("\tpci=config_acs=1@0008:00:00.0", True),
        ("# pci=config_acs=1@0008:00:00.0", False),
        ("  # pci=config_acs=1@0008:00:00.0", False),
        ('GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT" # pci=config_acs=1', False),
        ("# example only, nothing active here", False),
    ],
    ids=[
        "assignment",
        "bare",
        "tab-indented",
        "comment",
        "indented-comment",
        "inline-comment",
        "no-token",
    ],
)
def test_pcie_acs_config_check_only_accepts_an_active_setting(node, dropin, accepted):
    """A commented example must not satisfy the pre-reboot check, but indentation must.

    Pins the matcher: a drop-in that contributes nothing to the kernel command line has
    to fail here rather than surviving to a post-interrupt failure after the reboot.
    """
    configure(node, **OCI_GB300)
    assert sh(node, "mkdir -p /etc/default/grub.d") == 0
    assert sh(node, f"printf '%s\\n' {shell_quote(dropin)} > {ACS_DROPIN}") == 0

    rc = step(node, "configure_pcie_acs_check.sh", {"FAKE_RDMA_TOPO_CHECK": "fail"})
    if accepted:
        assert rc == 0, output(node)
        assert said(node, "pending reboot"), output(node)
    else:
        assert rc != 0, output(node)
        assert said(node, "does not contain an active"), output(node)


def test_pcie_acs_config_check_fails_when_nothing_was_written(node):
    configure(node, **OCI_GB300)

    assert step(node, "configure_pcie_acs_check.sh", {"FAKE_RDMA_TOPO_CHECK": "fail"}) != 0
    assert said(node, "no bootloader drop-in"), output(node)


def test_pcie_acs_is_idempotent_across_config_passes(node):
    """Re-running before the reboot regenerates the same drop-in without erroring."""
    configure(node, **OCI_GB300)
    failing = {"FAKE_RDMA_TOPO_CHECK": "fail"}

    assert step(node, "configure_pcie_acs.sh", failing) == 0, output(node)
    assert sh(node, f"cp {ACS_DROPIN} /tmp/dropin.first") == 0
    assert step(node, "configure_pcie_acs.sh", failing) == 0, output(node)

    assert same(node, "/tmp/dropin.first", ACS_DROPIN)


def test_pcie_acs_fails_when_rdma_topo_is_missing(node):
    """rdma_topo ships in the node image for this shape; its absence is a real failure."""
    configure(node, **OCI_GB300)

    assert step(node, "configure_pcie_acs.sh", {"RDMA_TOPO_BIN": "rdma_topo_absent"}) != 0
    assert said(node, "not found"), output(node)


def test_pcie_acs_post_interrupt_check_requires_acs_to_be_live(node):
    configure(node, **OCI_GB300)
    fixable = {"FAKE_RDMA_TOPO_CHECK": "fix"}

    # Pre-reboot: the drop-in exists but the running kernel is unchanged.
    assert step(node, "configure_pcie_acs.sh", fixable) == 0, output(node)
    assert sh(node, "rm -f /tmp/fake-rdma-topo/wrote-grub-acs") == 0
    assert step(node, "post_interrupt_pcie_acs_check.sh", fixable) != 0
    assert said(node, "did not take effect on this node"), output(node)

    # Post-reboot: the corrected values are live.
    assert sh(node, "touch /tmp/fake-rdma-topo/wrote-grub-acs") == 0
    assert step(node, "post_interrupt_pcie_acs_check.sh", fixable) == 0, output(node)
    assert said(node, "correct after reboot"), output(node)


def test_pcie_acs_failure_message_names_cause_impact_and_remedy(node):
    """Whoever investigates the failure must not need to read the source to act."""
    configure(node, **OCI_GB300)
    failing = {"FAKE_RDMA_TOPO_CHECK": "fail"}

    assert step(node, "configure_pcie_acs.sh", failing) == 0, output(node)
    assert step(node, "post_interrupt_pcie_acs_check.sh", failing) != 0

    # Cause: the drop-in never reached the booted kernel command line.
    assert said(node, "no config_acs argument"), output(node)
    # Impact: what the operator loses, and what workloads still need.
    assert said(node, "nvidia_peermem"), output(node)
    assert said(node, "NCCL_DMABUF_ENABLE=0"), output(node)
    # Remedy: the documented opt-out.
    assert said(node, "CONFIGURE_PCIE_ACS=false"), output(node)


@pytest.mark.parametrize("value", ["false", "FALSE", "0", "no", "off"])
def test_pcie_acs_can_be_switched_off_by_the_operator(node, value):
    """CONFIGURE_PCIE_ACS is the escape hatch for kernels that ignore pci=config_acs=."""
    configure(node, **OCI_GB300)
    off = {"CONFIGURE_PCIE_ACS": value, "FAKE_RDMA_TOPO_CHECK": "fail"}

    assert step(node, "configure_pcie_acs.sh", off) == 0, output(node)
    assert said(node, "switched off"), output(node)
    assert not exists(node, ACS_DROPIN)
    assert not exists(node, "/tmp/fake-rdma-topo/calls")

    # Both checks stand down too, so a switched-off node never fails post-interrupt.
    for check in ("configure_pcie_acs_check.sh", "post_interrupt_pcie_acs_check.sh"):
        assert step(node, check, off) == 0, output(node)
        assert said(node, "switched off"), output(node)


@pytest.mark.parametrize("value", ["true", "TRUE", "", "yes"])
def test_pcie_acs_stays_on_for_any_non_falsey_value(node, value):
    configure(node, **OCI_GB300)

    rc = step(node, "configure_pcie_acs.sh", {"CONFIGURE_PCIE_ACS": value, "FAKE_RDMA_TOPO_CHECK": "fail"})
    assert rc == 0, output(node)
    assert said(node, "reboot is required"), output(node)
    assert exists(node, ACS_DROPIN)


# ---------------------------------------------------------------------------
# ACS verification must not depend on GPU driver state
# ---------------------------------------------------------------------------


def test_pcie_acs_accepts_correct_acs_when_the_gpu_driver_is_absent(node):
    """`rdma_topo check` also asserts GPU topology, which this package does not control.

    On a new cluster this is every node: Skyhook taints it, the GPU operator cannot
    install drivers until Skyhook completes, and Skyhook cannot complete if this check
    waits on the driver. Keying on the tool's exit code deadlocks bringup, so the checks
    gate on the ACS lines instead.
    """
    configure(node, **OCI_GB300)
    nogpu = {"FAKE_RDMA_TOPO_CHECK": "nogpu"}

    # Correct ACS is recognised, so no bootloader rewrite is attempted.
    assert step(node, "configure_pcie_acs.sh", nogpu) == 0, output(node)
    assert said(node, "already correct"), output(node)
    assert not exists(node, ACS_DROPIN)

    assert step(node, "configure_pcie_acs_check.sh", nogpu) == 0, output(node)
    assert said(node, "values are correct"), output(node)

    # The post-interrupt check is the one that would have deadlocked a new cluster.
    assert step(node, "post_interrupt_pcie_acs_check.sh", nogpu) == 0, output(node)
    assert said(node, "correct after reboot"), output(node)


def test_pcie_acs_still_fails_when_acs_itself_is_wrong(node):
    """Ignoring GPU topology must not weaken the ACS assertion."""
    configure(node, **OCI_GB300)
    failing = {"FAKE_RDMA_TOPO_CHECK": "fail"}

    assert step(node, "configure_pcie_acs.sh", failing) == 0, output(node)
    assert said(node, "reboot is required"), output(node)
    assert step(node, "post_interrupt_pcie_acs_check.sh", failing) != 0
    assert said(node, "did not take effect on this node"), output(node)


def test_pcie_acs_rejects_unreadable_acs_state(node):
    """A diagnostic mentioning ACS is not an ACS result; unreadable must not pass."""
    configure(node, **OCI_GB300)
    unreadable = {"FAKE_RDMA_TOPO_CHECK": "unreadable"}

    # Treated as "not correct", so the correction is attempted rather than skipped.
    assert step(node, "configure_pcie_acs.sh", unreadable) == 0, output(node)
    assert said(node, "reboot is required"), output(node)

    # And it must not be reported as verified.
    assert step(node, "post_interrupt_pcie_acs_check.sh", unreadable) != 0
    assert said(node, "did not take effect on this node"), output(node)


# ---------------------------------------------------------------------------
# configure_iommu_passthrough.sh
#
# The policy turns on `uname -r`, so these pin it through the uname fake rather than
# inheriting whatever kernel the test host happens to run.
# ---------------------------------------------------------------------------


def on_kernel(version: str, **extra) -> dict:
    """Step env with the reported kernel version pinned."""
    return {"FAKE_UNAME_R": version, **extra}


def booted(node: DockerTestRunner, cmdline: str, *group_types: str) -> dict:
    """Stage a fake booted state and return the env that points the check at it.

    cmdline is written verbatim so a test can place iommu.passthrough more than once;
    group_types become one sysfs group each, which is how translation is detected.
    """
    cmds = [f"printf '%s\\n' {shell_quote(cmdline)} > {FAKE_CMDLINE}",
            f"rm -rf {FAKE_IOMMU_GROUPS}"]
    for index, group_type in enumerate(group_types):
        cmds.append(f"mkdir -p {FAKE_IOMMU_GROUPS}/{index}")
        cmds.append(
            f"printf '%s\\n' {shell_quote(group_type)} > {FAKE_IOMMU_GROUPS}/{index}/type"
        )
    assert sh(node, " && ".join(cmds)) == 0
    return {"PROC_CMDLINE": FAKE_CMDLINE, "IOMMU_GROUPS_DIR": FAKE_IOMMU_GROUPS}


@pytest.mark.parametrize("configmaps", OTHER_SHAPES, ids=OTHER_SHAPE_IDS)
def test_iommu_passthrough_is_a_noop_without_the_opt_in_marker(node, configmaps):
    configure(node, **configmaps)
    old = on_kernel(OLD_KERNEL)

    assert step(node, "configure_iommu_passthrough.sh", old) == 0, output(node)
    assert said(node, "nothing to do"), output(node)
    assert not exists(node, IOMMU_DROPIN)

    for check in ("configure_iommu_passthrough_check.sh",
                  "post_interrupt_iommu_passthrough_check.sh"):
        assert step(node, check, old) == 0, output(node)
        assert said(node, "nothing to verify"), output(node)


def test_iommu_passthrough_writes_the_dropin_on_an_affected_kernel(node):
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(OLD_KERNEL)) == 0
    assert said(node, "reboot is required"), output(node)
    assert contains(node, IOMMU_DROPIN, "iommu.passthrough=0")
    assert exists(node, "/tmp/fake-grub/update-grub-ran")


def test_iommu_passthrough_appends_rather_than_replacing(node):
    """The drop-in must supersede an earlier producer without depending on one.

    It contributes by appending to $GRUB_CMDLINE_LINUX, so it is correct whether or not
    the platform ships a drop-in of its own, and sorts last so its value is the one the
    kernel acts on.
    """
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(OLD_KERNEL)) == 0
    assert contains(node, IOMMU_DROPIN, 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX')


def test_iommu_passthrough_is_a_noop_on_a_fixed_kernel(node):
    """At or above the threshold the kernel handles PASID on an identity domain."""
    configure(node, **OCI_GB300)
    new = on_kernel(NEW_KERNEL)

    assert step(node, "configure_iommu_passthrough.sh", new) == 0, output(node)
    assert said(node, "passthrough is fine here"), output(node)
    assert not exists(node, IOMMU_DROPIN)

    for check in ("configure_iommu_passthrough_check.sh",
                  "post_interrupt_iommu_passthrough_check.sh"):
        assert step(node, check, new) == 0, output(node)


def test_iommu_passthrough_is_idempotent_across_config_passes(node):
    configure(node, **OCI_GB300)
    old = on_kernel(OLD_KERNEL)

    assert step(node, "configure_iommu_passthrough.sh", old) == 0, output(node)
    assert sh(node, f"cp {IOMMU_DROPIN} /tmp/iommu-dropin.first") == 0
    assert step(node, "configure_iommu_passthrough.sh", old) == 0, output(node)

    assert said(node, "already current"), output(node)
    assert same(node, "/tmp/iommu-dropin.first", IOMMU_DROPIN)


def test_iommu_passthrough_rewrites_a_stale_dropin(node):
    """A drop-in left by an older package version is corrected, not silently kept."""
    configure(node, **OCI_GB300)
    assert sh(node, "mkdir -p /etc/default/grub.d") == 0
    assert sh(node, f"printf '%s\\n' '# stale' > {IOMMU_DROPIN}") == 0

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(OLD_KERNEL)) == 0
    assert contains(node, IOMMU_DROPIN, "iommu.passthrough=0")


@pytest.mark.parametrize("value", ["false", "FALSE", "0", "no", "off"])
def test_iommu_passthrough_can_be_switched_off_by_the_operator(node, value):
    """The escape hatch for a kernel carrying a backported fix uname cannot see."""
    configure(node, **OCI_GB300)
    off = on_kernel(OLD_KERNEL, CONFIGURE_IOMMU_PASSTHROUGH=value)

    assert step(node, "configure_iommu_passthrough.sh", off) == 0, output(node)
    assert said(node, "switched off"), output(node)
    assert not exists(node, IOMMU_DROPIN)

    # Both checks stand down, so a switched-off node never fails post-interrupt.
    for check in ("configure_iommu_passthrough_check.sh",
                  "post_interrupt_iommu_passthrough_check.sh"):
        assert step(node, check, off) == 0, output(node)
        assert said(node, "switched off"), output(node)


@pytest.mark.parametrize("value", ["true", "TRUE", "1", "yes", "on"])
def test_iommu_passthrough_can_be_forced_on_a_fixed_kernel(node, value):
    """`true` overrides the version check, for a kernel auto reads wrongly."""
    configure(node, **OCI_GB300)

    rc = step(node, "configure_iommu_passthrough.sh",
              on_kernel(NEW_KERNEL, CONFIGURE_IOMMU_PASSTHROUGH=value))
    assert rc == 0, output(node)
    assert said(node, "reboot is required"), output(node)
    assert contains(node, IOMMU_DROPIN, "iommu.passthrough=0")


def test_iommu_passthrough_treats_an_unparseable_kernel_as_new_enough(node):
    """Applying a boot-affecting change to an unknown platform is the worse failure."""
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel("not-a-version")) == 0
    assert said(node, "cannot parse kernel version"), output(node)
    assert not exists(node, IOMMU_DROPIN)


def test_iommu_passthrough_config_check_fails_when_nothing_was_written(node):
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough_check.sh", on_kernel(OLD_KERNEL)) != 0
    assert said(node, "no bootloader drop-in"), output(node)


@pytest.mark.parametrize(
    ("dropin", "accepted"),
    [
        ('GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX iommu.passthrough=0"', True),
        ("iommu.passthrough=0", True),
        ("\tiommu.passthrough=0", True),
        ("# iommu.passthrough=0", False),
        ("  # iommu.passthrough=0", False),
        ('GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX" # iommu.passthrough=0', False),
        ("# example only, nothing active here", False),
    ],
    ids=[
        "assignment",
        "bare",
        "tab-indented",
        "comment",
        "indented-comment",
        "inline-comment",
        "no-token",
    ],
)
def test_iommu_passthrough_config_check_only_accepts_an_active_setting(
    node, dropin, accepted
):
    """A commented example must not satisfy the pre-reboot check, but indentation must."""
    configure(node, **OCI_GB300)
    assert sh(node, "mkdir -p /etc/default/grub.d") == 0
    assert sh(node, f"printf '%s\\n' {shell_quote(dropin)} > {IOMMU_DROPIN}") == 0

    rc = step(node, "configure_iommu_passthrough_check.sh", on_kernel(OLD_KERNEL))
    if accepted:
        assert rc == 0, output(node)
        assert said(node, "pending reboot"), output(node)
    else:
        assert rc != 0, output(node)
        assert said(node, "does not contain an active"), output(node)


def test_iommu_passthrough_post_interrupt_check_accepts_a_translated_node(node):
    configure(node, **OCI_GB300)
    env = on_kernel(OLD_KERNEL,
                    **booted(node, "root=x iommu.passthrough=1 quiet iommu.passthrough=0",
                             "DMA-FQ", "DMA-FQ"))

    assert step(node, "post_interrupt_iommu_passthrough_check.sh", env) == 0, output(node)
    assert said(node, "translation is active"), output(node)


def test_iommu_passthrough_post_interrupt_check_reads_the_last_cmdline_value(node):
    """The token legitimately appears twice; only the last one is what the kernel used.

    A drop-in that sorts before another producer leaves iommu.passthrough=1 in effect
    while =0 is still present on the command line. Matching the token anywhere would
    report that node as fixed, which is the failure this check exists to catch.
    """
    configure(node, **OCI_GB300)
    env = on_kernel(OLD_KERNEL,
                    **booted(node, "root=x iommu.passthrough=0 quiet iommu.passthrough=1",
                             "identity", "identity"))

    assert step(node, "post_interrupt_iommu_passthrough_check.sh", env) != 0
    assert said(node, "still resolves iommu.passthrough to 1"), output(node)


def test_iommu_passthrough_post_interrupt_check_requires_translation_to_be_live(node):
    """A correct command line is not evidence on its own; the SMMU must have acted."""
    configure(node, **OCI_GB300)
    env = on_kernel(OLD_KERNEL,
                    **booted(node, "root=x iommu.passthrough=1 quiet iommu.passthrough=0",
                             "identity", "identity"))

    assert step(node, "post_interrupt_iommu_passthrough_check.sh", env) != 0
    assert said(node, "still in bypass"), output(node)


def test_iommu_passthrough_failure_message_names_cause_impact_and_remedy(node):
    """Whoever investigates the failure must not need to read the source to act."""
    configure(node, **OCI_GB300)
    env = on_kernel(OLD_KERNEL,
                    **booted(node, "root=x iommu.passthrough=1", "identity"))

    assert step(node, "post_interrupt_iommu_passthrough_check.sh", env) != 0

    # Cause: the workaround did not reach the booted kernel.
    assert said(node, "did not take effect on this node"), output(node)
    # Impact: no CUDA context can be created, and where to look to confirm.
    assert said(node, "NO CUDA context"), output(node)
    assert said(node, "arm_smmu_write_ctx_desc"), output(node)
    # Remedy: the documented opt-out.
    assert said(node, "CONFIGURE_IOMMU_PASSTHROUGH=false"), output(node)


def test_iommu_passthrough_off_removes_a_previously_written_dropin(node):
    """`false` has to restore passthrough, not just stop maintaining the drop-in.

    A stale drop-in still contributes iommu.passthrough=0 at the next boot, so leaving it
    in place would make the documented escape hatch unable to do the thing it documents.
    """
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(OLD_KERNEL)) == 0
    assert exists(node, IOMMU_DROPIN)

    off = on_kernel(OLD_KERNEL, CONFIGURE_IOMMU_PASSTHROUGH="false")
    assert step(node, "configure_iommu_passthrough.sh", off) == 0, output(node)
    assert said(node, "reboot is required to restore"), output(node)
    assert not exists(node, IOMMU_DROPIN)


def test_iommu_passthrough_removes_the_dropin_after_a_kernel_upgrade(node):
    """A node upgraded past the threshold must not keep the workaround pinned on."""
    configure(node, **OCI_GB300)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(OLD_KERNEL)) == 0
    assert exists(node, IOMMU_DROPIN)

    assert step(node, "configure_iommu_passthrough.sh", on_kernel(NEW_KERNEL)) == 0
    assert said(node, "reboot is required to restore"), output(node)
    assert not exists(node, IOMMU_DROPIN)


def test_iommu_passthrough_removal_is_idempotent(node):
    """Standing down on a node that never had the drop-in must not claim it removed one."""
    configure(node, **OCI_GB300)
    off = on_kernel(OLD_KERNEL, CONFIGURE_IOMMU_PASSTHROUGH="false")

    assert step(node, "configure_iommu_passthrough.sh", off) == 0, output(node)
    assert not said(node, "Removed"), output(node)


def test_iommu_passthrough_post_interrupt_check_rejects_an_absent_value(node):
    """An absent token means nothing this package wrote reached the booted kernel.

    The drop-in sets iommu.passthrough explicitly, so its absence is a drop-in that never
    applied. Accepting it because the kernel happened to default to a translating domain
    would report a broken deployment as fixed.
    """
    configure(node, **OCI_GB300)
    env = on_kernel(OLD_KERNEL, **booted(node, "root=x quiet", "DMA-FQ"))

    assert step(node, "post_interrupt_iommu_passthrough_check.sh", env) != 0
    assert said(node, "carries no iommu.passthrough argument"), output(node)
    # Still reaches the shared diagnostic rather than exiting early.
    assert said(node, "NO CUDA context"), output(node)
    assert said(node, "CONFIGURE_IOMMU_PASSTHROUGH=false"), output(node)
