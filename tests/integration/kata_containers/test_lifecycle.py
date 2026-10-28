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

"""Lifecycle failure handling inside the repository's Docker test harness."""

from pathlib import Path

import pytest

from tests.helpers.docker_test import DockerTestRunner


STUB = Path(__file__).parent / "fakes/host-command.sh"
EXTRA_FILES = [(STUB, f"test-bin/{name}") for name in ("mount", "mkdir", "touch", "kata-deploy", "uname", "unshare", "chroot", "ctr", "systemctl", "k3s", "k0s", "microk8s")]
BASE_ENV = {
    "PATH": "/skyhook-package/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "TRACE": "/tmp/kata-trace", "ENV_TRACE": "/tmp/kata-env", "NODE_NAME": "test-node",
    "TEST_ARCH": "aarch64", "CONTAINER_RUNTIME_VERSION": "containerd://2.4.2",
}


def run_action(base_image, action="install", env=None, script="run-inner.sh", payload=False):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        files = EXTRA_FILES + ([(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy")] if payload else [])
        result = runner.run_script(script=script, script_args=[action],
                                   env_vars={**BASE_ENV, **(env or {})}, extra_files=files)
        trace = runner.container.exec_run(["cat", "/tmp/kata-trace"])
        lines = trace.output.decode().splitlines() if trace.exit_code == 0 else []
        selected = runner.container.exec_run(["cat", "/tmp/kata-env"])
        selection = selected.output.decode().strip() if selected.exit_code == 0 else ""
        return result, lines, selection


@pytest.mark.parametrize("env", [
    {"NODE_NAME": ""}, {"CONTAINER_RUNTIME_VERSION": "REPLACE_ME"},
    {"CONTAINER_RUNTIME_VERSION": "cri-o://1.34.0"}, {"INSTALLATION_PREFIX": "/other"},
    {"MULTI_INSTALL_SUFFIX": "other"}, {"K8S_DISTRIBUTION": "unknown"}, {"TEST_ARCH": "s390x"},
])
def test_invalid_target_fails_before_mounting(base_image, env):
    result, lines, _ = run_action(base_image, env=env)
    assert result.exit_code != 0
    assert lines == []


@pytest.mark.parametrize("action,code", [("validate", 0), ("reset", 2)])
def test_validation_does_not_mount(base_image, action, code):
    result, lines, _ = run_action(base_image, action=action)
    assert result.exit_code == code, result.stdout
    assert lines == []


def test_installs_cpu_erofs_with_private_mounts(base_image):
    result, lines, selection = run_action(base_image, env={"SHIMS_AARCH64": "qemu-nvidia-gpu-runtime-rs"})
    assert result.exit_code == 0, result.stdout
    runtime = "qemu-nvidia-cpu-runtime-rs"
    assert selection == f"{runtime}|erofs|{runtime}:erofs|config.toml"
    assert "mount --make-rprivate /" not in lines
    for mount in ("mount --bind /root /host", "mount --bind /root/opt/kata /opt/kata",
                  "mount --bind /root/etc/containerd /etc/containerd",
                  "mount --bind /skyhook-package/configmaps /custom-configs"):
        assert lines.index(mount) < lines.index("kata-deploy install-stage-artifacts")


@pytest.mark.parametrize("action,fail,forbidden", [
    ("install", "mount --bind /root /host", "kata-deploy "),
    ("install", "mount --bind /skyhook-package/configmaps /custom-configs", "kata-deploy "),
    ("install", "kata-deploy install-stage-host-check", "kata-deploy install-stage-artifacts"),
    ("uninstall", "kata-deploy cleanup-stage-revert-cri", "kata-deploy cleanup-stage-remove-artifacts"),
    ("uninstall", "mount --bind /root/opt /opt", "kata-deploy cleanup-stage-remove-artifacts"),
])
def test_failure_stops_host_mutation(base_image, action, fail, forbidden):
    result, lines, _ = run_action(base_image, action=action, env={"FAIL_COMMAND": fail})
    assert result.exit_code == 7, result.stdout
    assert not any(line.startswith(forbidden) for line in lines)
    if fail == "kata-deploy install-stage-host-check":
        assert "kata-deploy install-stage-cri" not in lines


def test_uninstall_reverts_cri_before_removing_artifacts(base_image):
    result, lines, _ = run_action(base_image, action="uninstall")
    assert result.exit_code == 0, result.stdout
    assert lines.index("kata-deploy cleanup-stage-revert-cri") < lines.index("kata-deploy cleanup-stage-remove-artifacts")
    assert "kata-deploy cleanup" not in lines
    assert lines.index("kata-deploy cleanup-stage-revert-cri") < lines.index("mount --bind /root/opt /opt") < lines.index("kata-deploy cleanup-stage-remove-artifacts")


def test_host_wrapper_rejects_missing_installer_before_unshare(base_image):
    result, lines, _ = run_action(base_image, script="run.sh")
    assert result.exit_code != 0
    assert "installer filesystem is missing" in result.stdout
    assert lines == []


def test_host_wrapper_propagates_namespace_failure(base_image):
    namespace = "unshare --mount --propagation private /skyhook-package/skyhook_dir/enter-installer.sh install"
    result, lines, _ = run_action(base_image, script="run.sh", payload=True,
                                 env={"FAIL_COMMAND": namespace})
    assert result.exit_code == 7, result.stdout
    assert lines == [namespace]


def test_installer_mount_failure_prevents_chroot(base_image):
    rootfs = "/skyhook-package/skyhook_dir/installer-rootfs"
    first_mount = f"mount --bind {rootfs} {rootfs}"
    result, lines, _ = run_action(base_image, script="enter-installer.sh",
                                 env={"FAIL_COMMAND": first_mount})
    assert result.exit_code == 7, result.stdout
    assert lines == [first_mount]


def test_installer_mounts_host_before_chroot(base_image):
    result, lines, _ = run_action(base_image, script="enter-installer.sh")
    assert result.exit_code == 0, result.stdout
    rootfs = "/skyhook-package/skyhook_dir/installer-rootfs"
    assert lines == [
        f"mount --bind {rootfs} {rootfs}",
        f"mount --rbind / {rootfs}/root",
        *[f"mount --rbind /{directory} {rootfs}/{directory}" for directory in ("proc", "sys", "dev")],
        f"chroot {rootfs} /bin/bash /usr/local/bin/nodewright-kata-stage install",
    ]


@pytest.mark.parametrize("action", ["install", "uninstall"])
def test_custom_containerd_config_reaches_installer(base_image, action):
    result, _, selection = run_action(base_image, action=action,
                                     env={"CONTAINERD_CONFIG_FILE_NAME": "config-dpu.toml"})
    assert result.exit_code == 0, result.stdout
    assert selection.endswith("|config-dpu.toml")


@pytest.mark.parametrize("name", ["/etc/containerd/dpu.toml", "../dpu.toml", ".", "..", " dpu.toml", "dpu.toml\n"])
def test_invalid_containerd_config_fails_before_mounting(base_image, name):
    result, lines, _ = run_action(base_image, script="run.sh",
                                 env={"CONTAINERD_CONFIG_FILE_NAME": name})
    assert result.exit_code != 0
    assert "simple filename" in result.stdout
    assert lines == []


@pytest.mark.parametrize("version", ["v2.4.2", "v2.3.0", "2.3.1-rc.1"])
def test_host_wrapper_detects_server_version(base_image, version):
    result, lines, selection = run_action(
        base_image, script="run.sh", payload=True,
        env={"CONTAINER_RUNTIME_VERSION": "", "TEST_CONTAINERD_VERSION": version},
    )
    assert result.exit_code == 0, result.stdout
    assert lines[0] == "ctr --address /run/containerd/containerd.sock --timeout 10s version"
    assert selection == f"containerd://{version.removeprefix('v')}"
    assert lines[1].startswith("unshare ")


@pytest.mark.parametrize("env", [
    {"FAIL_COMMAND": "ctr"}, {"TEST_CONTAINERD_VERSION": ""},
    {"TEST_CONTAINERD_VERSION": "unknown"},
])
def test_host_wrapper_rejects_failed_version_detection_before_mounting(base_image, env):
    result, lines, _ = run_action(base_image, script="run.sh", payload=True,
                                env={"CONTAINER_RUNTIME_VERSION": "", **env})
    assert result.exit_code != 0
    assert "containerd server" in result.stdout
    assert len(lines) == 1 and lines[0].startswith("ctr ")


DISTRIBUTIONS = [
    ("", "k8s", "/etc/containerd", "/run/containerd/containerd.sock", "ctr"),
    ("k3s", "k3s", "/var/lib/rancher/k3s/agent/etc/containerd", "/run/k3s/containerd/containerd.sock", "k3s ctr"),
    ("k3s-agent", "k3s", "/var/lib/rancher/k3s/agent/etc/containerd", "/run/k3s/containerd/containerd.sock", "k3s ctr"),
    ("rke2-server", "rke2", "/var/lib/rancher/rke2/agent/etc/containerd", "/run/k3s/containerd/containerd.sock", "ctr"),
    ("rke2-agent", "rke2", "/var/lib/rancher/rke2/agent/etc/containerd", "/run/k3s/containerd/containerd.sock", "ctr"),
    ("k0scontroller", "k0s", "/etc/k0s", "/run/k0s/containerd.sock", "k0s ctr"),
    ("k0sworker", "k0s", "/etc/k0s", "/run/k0s/containerd.sock", "k0s ctr"),
    ("snap.microk8s.daemon-containerd", "microk8s", "/var/snap/microk8s/current/args", "/var/snap/microk8s/common/run/containerd.sock", "microk8s ctr"),
]


@pytest.mark.parametrize("unit,distribution,config_dir,socket,client", DISTRIBUTIONS)
def test_wrapper_discovers_distribution_socket_and_server_version(base_image, unit, distribution, config_dir, socket, client):
    result, lines, selection = run_action(base_image, script="run.sh", payload=True,
        env={"CONTAINER_RUNTIME_VERSION": "", "TEST_SYSTEMD_UNITS": unit, "TEST_PROFILE": "1"})
    assert result.exit_code == 0, result.stdout
    assert selection == f"containerd://2.4.2|{distribution}|{config_dir}|{socket}"
    assert lines[0] == f"{client} --address {socket} --timeout 10s version"


@pytest.mark.parametrize("action", ["install", "uninstall"])
@pytest.mark.parametrize("unit,distribution,config_dir,socket,client", DISTRIBUTIONS)
def test_distribution_host_directory_is_normalized_for_native_stages(base_image, action, unit, distribution, config_dir, socket, client):
    result, lines, selection = run_action(base_image, action=action,
        env={"K8S_DISTRIBUTION": distribution, "TEST_PROFILE": "1"})
    assert result.exit_code == 0, result.stdout
    assert f"mount --bind /root{config_dir} /etc/containerd" in lines
    assert selection == f"containerd://2.4.2|{distribution}|{config_dir}|{socket}"


@pytest.mark.parametrize("env", [
    {"CONTAINERD_CONFIG_DIR": "relative"}, {"CONTAINERD_CONFIG_DIR": "/etc/../run"},
    {"CONTAINERD_CONFIG_DIR": "/"}, {"CONTAINERD_RUNTIME_SOCKET": "tcp://example:1234"},
    {"CONTAINERD_RUNTIME_SOCKET": "/run/../socket"},
    {"K8S_DISTRIBUTION": "k3s", "CONTAINERD_CONFIG_FILE_NAME": "custom.toml"},
    {"TEST_SYSTEMD_UNITS": "k3s rke2-server"},
])
def test_invalid_distribution_mapping_fails_before_host_commands(base_image, env):
    result, lines, _ = run_action(base_image, script="run.sh", payload=True, env=env)
    assert result.exit_code != 0
    assert not lines


def test_explicit_paths_override_discovered_defaults(base_image):
    result, lines, selection = run_action(base_image, script="run.sh", payload=True,
        env={"K8S_DISTRIBUTION": "k3s", "CONTAINERD_CONFIG_DIR": "/srv/k3s/agent/etc/containerd",
             "CONTAINERD_RUNTIME_SOCKET": "unix:///run/custom/containerd.sock",
             "CONTAINER_RUNTIME_VERSION": "", "TEST_PROFILE": "1"})
    assert result.exit_code == 0, result.stdout
    assert selection == "containerd://2.4.2|k3s|/srv/k3s/agent/etc/containerd|/run/custom/containerd.sock"
    assert lines[0] == "k3s ctr --address /run/custom/containerd.sock --timeout 10s version"


@pytest.mark.parametrize("declared", ["", "rke2"])
def test_uninstall_reuses_saved_profile_when_services_are_down(base_image, declared):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        env = {**BASE_ENV, "CONTAINER_RUNTIME_VERSION": "", "TEST_SYSTEMD_UNITS": "rke2-agent", "TEST_PROFILE": "1", "SKYHOOK_ROOT_DIR": "/skyhook-package/state"}
        files = EXTRA_FILES + [(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy"), (STUB, "state/keep")]
        result = runner.run_script(script="run.sh", script_args=["install"], env_vars=env, extra_files=files)
        assert result.exit_code == 0, result.stdout
        # Simulate a new staged generation, with the stable profile retained and service queries failing.
        env.update(TEST_SYSTEMD_UNITS="", FAIL_COMMAND="ctr", K8S_DISTRIBUTION=declared)
        env.update(SKYHOOK_DIR="/skyhook-package/generation-2", STEP_ROOT="/skyhook-package/skyhook_dir")
        result = runner.container.exec_run(["bash", "/skyhook-package/skyhook_dir/run.sh", "uninstall"], environment=env)
        assert result.exit_code == 0, result.output.decode()
        selected = runner.container.exec_run(["cat", "/tmp/kata-env"]).output.decode()
        assert selected == "containerd://2.4.2|rke2|/var/lib/rancher/rke2/agent/etc/containerd|/run/k3s/containerd/containerd.sock"



def test_rke2_uses_its_bundled_client_from_a_custom_data_directory(base_image):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        files = EXTRA_FILES + [(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy"),
                               (STUB, "rke2/bin/ctr")]
        env = {**BASE_ENV, "CONTAINER_RUNTIME_VERSION": "", "K8S_DISTRIBUTION": "rke2",
               "CONTAINERD_CONFIG_DIR": "/skyhook-package/rke2/agent/etc/containerd", "TEST_CLIENT_TRACE": "1"}
        result = runner.run_script(script="run.sh", script_args=["install"], env_vars=env, extra_files=files)
        assert result.exit_code == 0, result.stdout
        actual = runner.container.exec_run(["cat", "/tmp/kata-client"]).output.decode()
        assert actual == "/skyhook-package/rke2/bin/ctr"


@pytest.mark.parametrize("action,expected", [
    ("prepare", ["install-stage-selinux-policy", "install-stage-load-kernel-modules", "install-stage-host-check"]),
    ("check-prepared", ["install-stage-host-check"]),
])
def test_preflight_checks_prerequisites_without_installing_runtime(base_image, action, expected):
    result, lines, _ = run_action(base_image, action=action)
    assert result.exit_code == 0, result.stdout
    assert [line for line in lines if line.startswith("kata-deploy ")] == [f"kata-deploy {name}" for name in expected]


@pytest.mark.parametrize("fail", ["install-stage-selinux-policy", "install-stage-load-kernel-modules", "install-stage-host-check"])
def test_preflight_propagates_native_prerequisite_failure(base_image, fail):
    result, lines, _ = run_action(base_image, action="prepare", env={"FAIL_COMMAND": f"kata-deploy {fail}"})
    assert result.exit_code == 7, result.stdout
    assert lines[-1] == f"kata-deploy {fail}"



@pytest.mark.parametrize("installed", [False, True])
def test_finalize_removes_staged_payload_only_after_successful_validation(base_image, installed):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        files = EXTRA_FILES + [(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy")]
        result = runner.run_script(script="run.sh", script_args=["finalize"],
            env_vars=BASE_ENV, extra_files=files)
        assert result.exit_code != 0
        rootfs = "/skyhook-package/skyhook_dir/installer-rootfs"
        assert runner.container.exec_run(["test", "-d", rootfs]).exit_code == 0
        if installed:
            setup = runner.container.exec_run(["bash", "-c",
                "/bin/mkdir -p /opt/kata/runtime-rs/bin /opt/kata/share/defaults/kata-containers/runtime-rs && "
                "cp /bin/true /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 && "
                "echo config > /opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-nvidia-cpu-runtime-rs.toml"])
            assert setup.exit_code == 0, setup.output.decode()
            env = {**BASE_ENV, "STEP_ROOT": "/skyhook-package/skyhook_dir", "SKYHOOK_DIR": "/skyhook-package"}
            for action, succeeds in (("check-finalized", False), ("finalize", True), ("check-finalized", True), ("finalize", True)):
                result = runner.container.exec_run(["bash", "/skyhook-package/skyhook_dir/run.sh", action], environment=env)
                assert (result.exit_code == 0) is succeeds, result.output.decode()
            assert runner.container.exec_run(["test", "-e", rootfs]).exit_code != 0


@pytest.mark.parametrize("fail", [False, True])
def test_uninstall_removes_staged_payload_after_namespace_exits_successfully(base_image, fail):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        namespace = "unshare --mount --propagation private /skyhook-package/skyhook_dir/enter-installer.sh uninstall"
        env = {**BASE_ENV, "FAIL_COMMAND": namespace if fail else ""}
        result = runner.run_script(script="run.sh", script_args=["uninstall"], env_vars=env,
            extra_files=EXTRA_FILES + [(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy")])
        assert result.exit_code == (7 if fail else 0), result.stdout
        retained = runner.container.exec_run(["test", "-d", "/skyhook-package/skyhook_dir/installer-rootfs"]).exit_code == 0
        assert retained is fail


@pytest.mark.parametrize("version", ["containerd://1.7.0", "containerd://2.2.3"])
def test_dmverity_profile_rejects_old_containerd_before_host_mutation(base_image, version):
    result, lines, _ = run_action(base_image, script="run.sh", action="prepare", payload=True,
        env={"CONTAINER_RUNTIME_VERSION": version})
    assert result.exit_code != 0
    assert "requires containerd >= 2.3" in result.stdout
    assert lines == []


def test_cleanup_remains_available_for_an_incompatible_old_installation(base_image):
    result, lines, _ = run_action(base_image, script="run.sh", action="uninstall", payload=True,
        env={"CONTAINER_RUNTIME_VERSION": "containerd://2.2.3"})
    assert result.exit_code == 0, result.stdout
    assert any(line.startswith("unshare ") for line in lines)


@pytest.mark.parametrize("fail", [False, True])
def test_guest_gate_must_succeed_before_finalization_removes_payload(base_image, fail):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        setup = runner.run_script(script="run.sh", script_args=["validate"], env_vars=BASE_ENV,
            extra_files=EXTRA_FILES + [(STUB, "skyhook_dir/installer-rootfs/usr/bin/kata-deploy")])
        assert setup.exit_code == 0, setup.stdout
        prepare = runner.container.exec_run(["bash", "-c", "/bin/mkdir -p /opt/kata/runtime-rs/bin /opt/kata/share/defaults/kata-containers/runtime-rs && cp /bin/true /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 && echo config > /opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-nvidia-cpu-runtime-rs.toml"])
        assert prepare.exit_code == 0, prepare.output.decode()
        namespace = "unshare --mount --propagation private /skyhook-package/skyhook_dir/enter-installer.sh smoke"
        env = {**BASE_ENV, "STEP_ROOT": "/skyhook-package/skyhook_dir", "SKYHOOK_DIR": "/skyhook-package", "FAIL_COMMAND": namespace if fail else ""}
        result = runner.container.exec_run(["bash", "/skyhook-package/skyhook_dir/run.sh", "finalize"], environment=env)
        assert result.exit_code == (7 if fail else 0), result.output.decode()
        rootfs = runner.container.exec_run(["test", "-d", "/skyhook-package/skyhook_dir/installer-rootfs"]).exit_code == 0
        receipt = runner.container.exec_run(["test", "-f", "/skyhook-package/skyhook_dir/smoke-tested"]).exit_code == 0
        assert rootfs is fail and receipt is not fail
        check = runner.container.exec_run(["bash", "/skyhook-package/skyhook_dir/run.sh", "check-finalized"], environment=env)
        assert (check.exit_code == 0) is not fail
