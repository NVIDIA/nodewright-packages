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

"""Lifecycle tests for the bind-mount package."""

import hashlib
from pathlib import Path

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


SCRIPT = "/skyhook-package/skyhook_dir/bind_mount.sh"
SOURCE = "/mnt/k8s-disks/0"
TARGET = "/mnt/data"
SECOND_TARGET = "/mnt/log"
UNIT_NAME = "mnt-data.mount"
UNIT_FILE = "/etc/systemd/system/mnt-data.mount"
KUBELET_UNITS = ("kubelet.service", "snap.kubelet-eks.daemon.service")
SECOND_UNIT_FILE = "/etc/systemd/system/mnt-log.mount"
SKYHOOK_NAME = "local-data-bind"
SKYHOOK_UID = "11111111-2222-3333-4444-555555555555"
PACKAGE_KEY = "bind-data"
PACKAGE_VERSION = "0.1.1"
STATE_ROOT = "/var/lib/nodewright-packages/bind-mount"
FAKES = Path(__file__).parent / "fakes"
EXTRA_FILES = [(path, f"test-bin/{path.name}") for path in FAKES.iterdir()]
CONFIG = {
    "source": SOURCE,
    "target": TARGET,
    "expected-source-fstype": "xfs",
    "expected-source-device-prefix": "/dev/md",
}
BASE_ENV = {
    "SKYHOOK_DIR": "/skyhook-package",
    "SKYHOOK_RESOURCE_ID": f"{SKYHOOK_NAME}-{SKYHOOK_UID}-1_{PACKAGE_KEY}_{PACKAGE_VERSION}",
    "PATH": "/skyhook-package/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "FAKE_SOURCE": SOURCE,
    "FAKE_TARGET": TARGET,
    "FAKE_SOURCE_DEVICE": "/dev/md127",
    "FAKE_SOURCE_FSTYPE": "xfs",
    "FAKE_SOURCE_MOUNTED": "true",
    "FAKE_TARGET_ACTIVE": "false",
    "FAKE_SAME_INODE": "true",
}


def resource_id(
    package_key=PACKAGE_KEY,
    *,
    generation=1,
    version=PACKAGE_VERSION,
    skyhook_name=SKYHOOK_NAME,
    skyhook_uid=SKYHOOK_UID,
):
    return f"{skyhook_name}-{skyhook_uid}-{generation}_{package_key}_{version}"


def instance_hash(
    package_key=PACKAGE_KEY,
    *,
    skyhook_name=SKYHOOK_NAME,
    skyhook_uid=SKYHOOK_UID,
):
    instance_id = f"{skyhook_name}-{skyhook_uid}/{package_key}"
    return hashlib.sha256(instance_id.encode()).hexdigest()


def state_path(
    filename="state",
    package_key=PACKAGE_KEY,
    *,
    skyhook_name=SKYHOOK_NAME,
    skyhook_uid=SKYHOOK_UID,
):
    return f"{STATE_ROOT}/{instance_hash(package_key, skyhook_name=skyhook_name, skyhook_uid=skyhook_uid)}/{filename}"


def state_dir(
    package_key=PACKAGE_KEY,
    *,
    skyhook_name=SKYHOOK_NAME,
    skyhook_uid=SKYHOOK_UID,
):
    return f"{STATE_ROOT}/{instance_hash(package_key, skyhook_name=skyhook_name, skyhook_uid=skyhook_uid)}"


def lock_path(
    package_key=PACKAGE_KEY,
    *,
    skyhook_name=SKYHOOK_NAME,
    skyhook_uid=SKYHOOK_UID,
):
    return f"{STATE_ROOT}/.{instance_hash(package_key, skyhook_name=skyhook_name, skyhook_uid=skyhook_uid)}.lock"


STATE_FILE = state_path()
UNINSTALL_STATE_FILE = state_path("uninstall-state")


def start_runner(base_image, mode="install", env=None, config=None):
    runner = DockerTestRunner(package="bind-mount", base_image=base_image)
    result = runner.run_script(
        script="bind_mount.sh",
        script_args=[mode],
        configmaps=config or CONFIG,
        env_vars={**BASE_ENV, **(env or {})},
        extra_files=EXTRA_FILES,
    )
    return runner, result


def exec_mode(runner, mode, env=None):
    result = runner.container.exec_run(
        ["bash", SCRIPT, mode],
        environment={**BASE_ENV, **(env or {})},
    )
    return result.exit_code, result.output.decode("utf-8", errors="replace")


def write_config_value(runner, name, value):
    result = runner.container.exec_run(
        [
            "bash",
            "-c",
            f'printf "%s" "$CONFIG_VALUE" > /skyhook-package/configmaps/{name}',
        ],
        environment={"CONFIG_VALUE": value},
    )
    assert result.exit_code == 0, result.output.decode("utf-8", errors="replace")


def path_exists(runner, path):
    result = runner.container.exec_run(["test", "-e", path])
    return result.exit_code == 0


def assert_no_staging_directories(runner):
    result = runner.container.exec_run(
        [
            "bash",
            "-c",
            "shopt -s nullglob; paths=(/etc/systemd/system/.bind-mount.*); "
            "((${#paths[@]} == 0))",
        ]
    )
    assert result.exit_code == 0, result.output.decode("utf-8", errors="replace")


def test_install_prepares_owned_unit_without_activating_it(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "activate it through the package's controlled interrupt")
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(STATE_FILE)
        unit = runner.get_file_contents(UNIT_FILE)
        assert "# Managed by NodeWright package bind-mount" in unit
        assert f"What={SOURCE}" in unit
        assert f"Where={TARGET}" in unit
        assert f"AssertPathIsMountPoint={SOURCE}" in unit
        assert f"AssertPathIsReadWrite={SOURCE}" in unit
        assert f"AssertDirectoryNotEmpty=!{TARGET}" in unit
        assert "Before=local-fs.target kubelet.service snap.kubelet-eks.daemon.service" in unit
        assert "RequiredBy=kubelet.service snap.kubelet-eks.daemon.service" in unit
        for kubelet_unit in KUBELET_UNITS:
            requires_link = f"/etc/systemd/system/{kubelet_unit}.requires/{UNIT_NAME}"
            resolved = runner.container.exec_run(["readlink", "-f", requires_link])
            assert resolved.exit_code == 0, resolved.output.decode("utf-8", errors="replace")
            assert resolved.output.decode().strip() == UNIT_FILE
        assert_no_staging_directories(runner)
    finally:
        runner.cleanup()


def test_install_and_prepared_check_are_idempotent(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 0, output
        exit_code, output = exec_mode(runner, "prepared-check")
        assert exit_code == 0, output
        assert "Prepared mount definition" in output
    finally:
        runner.cleanup()


def test_prepared_check_rejects_missing_kubelet_dependency_link(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        requires_link = (
            f"/etc/systemd/system/{KUBELET_UNITS[0]}.requires/{UNIT_NAME}"
        )
        removed = runner.container.exec_run(["rm", "-f", requires_link])
        assert removed.exit_code == 0, removed.output.decode(
            "utf-8", errors="replace"
        )

        exit_code, output = exec_mode(runner, "prepared-check")
        assert exit_code == 1
        assert f"required dependency link '{requires_link}' is missing" in output
    finally:
        runner.cleanup()


def test_prepared_check_rejects_misdirected_kubelet_dependency_link(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        requires_link = (
            f"/etc/systemd/system/{KUBELET_UNITS[1]}.requires/{UNIT_NAME}"
        )
        replaced = runner.container.exec_run(
            ["ln", "-sfn", "/tmp/foreign.mount", requires_link]
        )
        assert replaced.exit_code == 0, replaced.output.decode(
            "utf-8", errors="replace"
        )

        exit_code, output = exec_mode(runner, "prepared-check")
        assert exit_code == 1
        assert f"required dependency link '{requires_link}' resolves" in output
        assert "expected '/etc/systemd/system/mnt-data.mount'" in output
    finally:
        runner.cleanup()


def test_install_refreshes_owned_legacy_template(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        current_unit = runner.get_file_contents(UNIT_FILE)
        legacy_unit = current_unit.replace(
            f"AssertDirectoryNotEmpty=!{TARGET}\n",
            "",
        )
        setup = runner.container.exec_run(
            ["bash", "-c", f'printf "%s" "$UNIT_CONTENT" > {UNIT_FILE}'],
            environment={"UNIT_CONTENT": legacy_unit},
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 0, output
        assert runner.get_file_contents(UNIT_FILE) == current_unit
        assert runner.file_exists(STATE_FILE)
        assert_no_staging_directories(runner)
    finally:
        runner.cleanup()


def test_failed_owned_refresh_preserves_previous_unit(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        current_unit = runner.get_file_contents(UNIT_FILE)
        legacy_unit = current_unit.replace(
            f"AssertDirectoryNotEmpty=!{TARGET}\n",
            "",
        )
        setup = runner.container.exec_run(
            ["bash", "-c", f'printf "%s" "$UNIT_CONTENT" > {UNIT_FILE}'],
            environment={"UNIT_CONTENT": legacy_unit},
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_VERIFY_FAIL": "true"},
        )
        assert exit_code == 1
        assert "systemd rejected rendered unit" in output
        assert runner.get_file_contents(UNIT_FILE) == legacy_unit
        assert runner.file_exists(STATE_FILE)
        assert_no_staging_directories(runner)
    finally:
        runner.cleanup()


def test_receipt_identity_survives_generation_and_version_churn(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "prepared-check",
            {
                "SKYHOOK_RESOURCE_ID": resource_id(
                    generation=9,
                    version="0.2.0",
                )
            },
        )
        assert exit_code == 0, output
        assert runner.file_exists(STATE_FILE)
        assert "Prepared mount definition" in output
    finally:
        runner.cleanup()


def test_instance_lock_rejects_symlink(base_image):
    runner, result = start_runner(
        base_image,
        mode="noop",
        env={"SKYHOOK_RESOURCE_ID": resource_id("bootstrap")},
    )
    try:
        assert_exit_code(result, 0)
        result = runner.container.exec_run(
            ["ln", "-s", "/tmp/foreign-lock", lock_path()]
        )
        assert result.exit_code == 0, result.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 1
        assert "refusing symlinked instance lock" in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_instance_lock_timeout_fails_closed(base_image):
    runner, result = start_runner(
        base_image,
        mode="noop",
        env={"FAKE_FLOCK_TIMEOUT_MODE": "-x"},
    )
    try:
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "timed out after 30s acquiring instance lock")
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_state_root_lock_timeout_fails_closed(base_image):
    runner, result = start_runner(
        base_image,
        mode="uninstall-check",
        env={"FAKE_FLOCK_TIMEOUT_MODE": "-x"},
    )
    try:
        assert_exit_code(result, 1)
        assert_output_contains(
            result.stdout,
            "timed out after 30s acquiring exclusive state-root lock",
        )
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_symlinked_state_directory(base_image):
    runner, result = start_runner(
        base_image,
        mode="noop",
        env={"SKYHOOK_RESOURCE_ID": resource_id("bootstrap")},
    )
    try:
        assert_exit_code(result, 0)
        setup = runner.container.exec_run(
            [
                "bash",
                "-c",
                f"mkdir -p /tmp/foreign-state && ln -s /tmp/foreign-state {state_dir()}",
            ]
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 1
        assert "refusing symlinked state directory" in output
        assert not runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_prepared_check_rejects_symlinked_receipt(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        setup = runner.container.exec_run(
            [
                "bash",
                "-c",
                f"rm -f {STATE_FILE} && touch /tmp/foreign-state && "
                f"ln -s /tmp/foreign-state {STATE_FILE}",
            ]
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "prepared-check")
        assert exit_code == 1
        assert "refusing symlinked state file" in output
        assert runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_overlapping_generations_serialize_shared_receipt(base_image):
    runner, result = start_runner(
        base_image,
        mode="noop",
        env={"SKYHOOK_RESOURCE_ID": resource_id("bootstrap")},
    )
    try:
        assert_exit_code(result, 0)
        setup = runner.container.exec_run(
            [
                "bash",
                "-c",
                "cp -a /skyhook-package /skyhook-package-second && "
                f"printf '%s' '{SECOND_TARGET}' > "
                "/skyhook-package-second/configmaps/target",
            ]
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        concurrent = runner.container.exec_run(
            [
                "bash",
                "-c",
                f"""
set +e
FAKE_VERIFY_DELAY=1 FAKE_VERIFY_STARTED_FILE=/tmp/first-verify-started \
    bash {SCRIPT} install >/tmp/first-install.out 2>&1 &
first_pid=$!
for _ in $(seq 1 100); do
    [[ -e /tmp/first-verify-started ]] && break
    sleep 0.05
done
if [[ ! -e /tmp/first-verify-started ]]; then
    wait "${{first_pid}}"
    cat /tmp/first-install.out
    exit 20
fi
SKYHOOK_DIR=/skyhook-package-second \
SKYHOOK_RESOURCE_ID={resource_id(generation=2)} \
FAKE_TARGET={SECOND_TARGET} \
    bash {SCRIPT} install >/tmp/second-install.out 2>&1 &
second_pid=$!
wait "${{first_pid}}"
first_status=$?
wait "${{second_pid}}"
second_status=$?
cat /tmp/first-install.out
cat /tmp/second-install.out
[[ "${{first_status}}" == 0 && "${{second_status}}" == 0 ]]
""",
            ],
            environment=BASE_ENV,
        )
        output = concurrent.output.decode("utf-8", errors="replace")
        assert concurrent.exit_code == 0, output
        assert not runner.file_exists(UNIT_FILE)
        assert runner.file_exists(SECOND_UNIT_FILE)
        assert runner.file_exists(STATE_FILE)
        state = runner.get_file_contents(STATE_FILE)
        assert f"target={SECOND_TARGET}" in state
        assert "unit=mnt-log.mount" in state
    finally:
        runner.cleanup()


def test_recreated_skyhook_uid_cannot_adopt_existing_unit(base_image):
    runner, result = start_runner(base_image)
    new_uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)

        exit_code, output = exec_mode(
            runner,
            "install",
            {
                "SKYHOOK_RESOURCE_ID": resource_id(skyhook_uid=new_uid),
            },
        )
        assert exit_code == 1
        assert "owned by another package instance" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert not runner.file_exists(state_path(skyhook_uid=new_uid))

        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])
        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {
                "SKYHOOK_RESOURCE_ID": resource_id(
                    generation=2,
                    skyhook_uid=new_uid,
                )
            },
        )
        assert exit_code == 0, output
        assert "nothing installed" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_active_check_validates_host_mount_identity(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner, "active-check", {"FAKE_TARGET_ACTIVE": "true"}
        )
        assert exit_code == 0, output
        assert "Active bind mount" in output
    finally:
        runner.cleanup()


def test_active_check_fails_before_interrupt(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(runner, "active-check")
        assert exit_code == 1
        assert "is not active" in output
    finally:
        runner.cleanup()


def test_install_rejects_unexpected_source_filesystem(base_image):
    runner, result = start_runner(
        base_image, env={"FAKE_SOURCE_FSTYPE": "ext4"}
    )
    try:
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "has filesystem 'ext4', expected 'xfs'")
        assert not runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_source_that_is_not_exact_mount(base_image):
    runner, result = start_runner(
        base_image,
        env={"FAKE_SOURCE_MOUNTED": "false"},
    )
    try:
        assert_exit_code(result, 1)
        assert_output_contains(
            result.stdout,
            f"source '{SOURCE}' resolves to '/', not an exact mount point",
        )
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_nonempty_target(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(
            ["bash", "-c", f"mkdir -p {TARGET} && touch {TARGET}/existing-cache"]
        )
        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 1
        assert "is not empty" in output
        assert not runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_rejected_config_change_preserves_previous_definition(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)
        original_state = runner.get_file_contents(STATE_FILE)
        write_config_value(runner, "target", SECOND_TARGET)
        setup = runner.container.exec_run(
            ["bash", "-c", f"mkdir -p {SECOND_TARGET} && touch {SECOND_TARGET}/existing"]
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_TARGET": SECOND_TARGET},
        )
        assert exit_code == 1
        assert "is not empty" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert runner.get_file_contents(STATE_FILE) == original_state
        assert not runner.file_exists(SECOND_UNIT_FILE)
    finally:
        runner.cleanup()


def test_failed_config_change_verification_preserves_previous_definition(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)
        original_state = runner.get_file_contents(STATE_FILE)
        write_config_value(runner, "target", SECOND_TARGET)

        exit_code, output = exec_mode(
            runner,
            "install",
            {
                "FAKE_TARGET": SECOND_TARGET,
                "FAKE_VERIFY_FAIL": "true",
            },
        )
        assert exit_code == 1
        assert "systemd rejected rendered unit" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert runner.get_file_contents(STATE_FILE) == original_state
        assert not runner.file_exists(SECOND_UNIT_FILE)
        assert_no_staging_directories(runner)
    finally:
        runner.cleanup()


def test_install_rejects_different_active_mount(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_TARGET_ACTIVE": "true", "FAKE_SAME_INODE": "false"},
        )
        assert exit_code == 1
        assert "already a different mount" in output
    finally:
        runner.cleanup()


def test_install_rejects_read_only_active_mount(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_TARGET_ACTIVE": "true", "FAKE_TARGET_OPTIONS": "ro,relatime"},
        )
        assert exit_code == 1
        assert "already a different mount" in output
    finally:
        runner.cleanup()


def test_install_rejects_read_only_covering_mount(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_COVERING_OPTIONS": "ro,relatime"},
        )
        assert exit_code == 1
        assert "covered by read-only mount" in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_prepared_check_rejects_read_only_covering_mount(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "prepared-check",
            {"FAKE_COVERING_OPTIONS": "ro,relatime"},
        )
        assert exit_code == 1
        assert "covered by read-only mount" in output
    finally:
        runner.cleanup()


def test_active_check_rejects_read_only_mount(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "active-check",
            {"FAKE_TARGET_ACTIVE": "true", "FAKE_TARGET_OPTIONS": "ro,relatime"},
        )
        assert exit_code == 1
        assert "does not bind the desired source" in output
    finally:
        runner.cleanup()


def test_install_rejects_overlapping_paths(base_image):
    config = {**CONFIG, "target": f"{SOURCE}/data"}
    runner, result = start_runner(base_image, config=config)
    try:
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "source and target must be disjoint paths")
        assert not runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_foreign_unit(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(
            ["bash", "-c", f"mkdir -p /etc/systemd/system && printf foreign > {UNIT_FILE}"]
        )
        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 1
        assert "owned by another package instance" in output
        assert runner.get_file_contents(UNIT_FILE) == "foreign"
    finally:
        runner.cleanup()


def test_install_rejects_same_named_unit_from_foreign_load_path(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        foreign_fragment = "/usr/lib/systemd/system/mnt-data.mount"
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_FRAGMENT_PATH": foreign_fragment},
        )
        assert exit_code == 1
        assert "already exists outside" in output
        assert foreign_fragment in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_same_named_transient_unit(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_LOAD_STATE": "loaded"},
        )
        assert exit_code == 1
        assert "already exists outside" in output
        assert "fragment ''" in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_install_fails_closed_when_systemd_state_is_unreadable(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        exit_code, output = exec_mode(
            runner,
            "install",
            {"FAKE_SHOW_FAIL": "true"},
        )
        assert exit_code == 1
        assert "could not inspect systemd unit" in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
    finally:
        runner.cleanup()


def test_two_package_aliases_prepare_disjoint_mounts(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        write_config_value(runner, "target", SECOND_TARGET)

        exit_code, output = exec_mode(
            runner,
            "install",
            {
                "SKYHOOK_RESOURCE_ID": resource_id("bind-log"),
                "FAKE_TARGET": SECOND_TARGET,
            },
        )
        assert exit_code == 0, output
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(SECOND_UNIT_FILE)
        assert runner.file_exists(state_path(package_key=PACKAGE_KEY))
        assert runner.file_exists(state_path(package_key="bind-log"))
        assert f"instance={SKYHOOK_NAME}-{SKYHOOK_UID}/{PACKAGE_KEY}" in runner.get_file_contents(
            UNIT_FILE
        )
        assert f"instance={SKYHOOK_NAME}-{SKYHOOK_UID}/bind-log" in runner.get_file_contents(
            SECOND_UNIT_FILE
        )
    finally:
        runner.cleanup()


def test_same_target_collision_does_not_share_or_replace_owner(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)

        exit_code, output = exec_mode(
            runner,
            "install",
            {"SKYHOOK_RESOURCE_ID": resource_id("bind-log")},
        )
        assert exit_code == 1
        assert "owned by another package instance" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert runner.file_exists(STATE_FILE)
        assert not runner.file_exists(state_path(package_key="bind-log"))
    finally:
        runner.cleanup()


def test_configless_uninstall_of_missing_alias_does_not_remove_another(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])

        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {"SKYHOOK_RESOURCE_ID": resource_id("bind-log", generation=2)},
        )
        assert exit_code == 0, output
        assert "nothing installed" in output
        assert runner.get_file_contents(UNIT_FILE) == original_unit
        assert runner.file_exists(STATE_FILE)
        assert not runner.file_exists(state_path("uninstall-state", "bind-log"))
    finally:
        runner.cleanup()


def test_configless_uninstall_is_scoped_to_selected_alias(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        write_config_value(runner, "target", SECOND_TARGET)
        exit_code, output = exec_mode(
            runner,
            "install",
            {
                "SKYHOOK_RESOURCE_ID": resource_id("bind-log"),
                "FAKE_TARGET": SECOND_TARGET,
            },
        )
        assert exit_code == 0, output
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])

        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {
                "SKYHOOK_RESOURCE_ID": resource_id("bind-log", generation=2),
                "FAKE_TARGET": SECOND_TARGET,
            },
        )
        assert exit_code == 0, output
        assert not runner.file_exists(SECOND_UNIT_FILE)
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(STATE_FILE)
        assert runner.file_exists(state_path("uninstall-state", "bind-log"))

        exit_code, output = exec_mode(
            runner,
            "uninstall-check",
            {
                "SKYHOOK_RESOURCE_ID": resource_id("bind-log", generation=2),
                "FAKE_TARGET": SECOND_TARGET,
            },
        )
        assert exit_code == 0, output
        assert not path_exists(runner, state_dir(package_key="bind-log"))
        assert not runner.file_exists(lock_path(package_key="bind-log"))
        assert runner.file_exists(STATE_FILE)
        assert runner.file_exists(lock_path())
        assert runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_install_rejects_fstab_owner(base_image):
    runner, result = start_runner(base_image, mode="noop")
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(
            ["bash", "-c", f"printf '/dev/other {TARGET} ext4 defaults 0 2\\n' >> /etc/fstab"]
        )
        exit_code, output = exec_mode(runner, "install")
        assert exit_code == 1
        assert "/etc/fstab already owns target" in output
        assert not runner.file_exists(UNIT_FILE)
    finally:
        runner.cleanup()


def test_install_removes_new_unit_when_systemd_rejects_it(base_image):
    runner, result = start_runner(base_image, env={"FAKE_VERIFY_FAIL": "true"})
    try:
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "systemd rejected")
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
        assert_no_staging_directories(runner)
    finally:
        runner.cleanup()


def test_failed_enable_retains_cleanup_receipt(base_image):
    runner, result = start_runner(base_image, env={"FAKE_ENABLE_FAIL": "true"})
    try:
        assert_exit_code(result, 1)
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(STATE_FILE)

        exit_code, output = exec_mode(runner, "uninstall")
        assert exit_code == 0, output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
        assert runner.file_exists(UNINSTALL_STATE_FILE)
    finally:
        runner.cleanup()


def test_failed_dependency_parser_does_not_mark_unit_enabled(base_image):
    runner, result = start_runner(
        base_image, env={"FAKE_REQUIRED_BY_PARSE_FAIL": "true"}
    )
    try:
        assert_exit_code(result, 1)
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(STATE_FILE)
        assert not runner.file_exists("/tmp/fake-systemctl/enabled-mnt-data.mount")
        for kubelet_unit in KUBELET_UNITS:
            requires_link = (
                f"/etc/systemd/system/{kubelet_unit}.requires/{UNIT_NAME}"
            )
            assert not runner.file_exists(requires_link)
    finally:
        runner.cleanup()


def test_failed_dependency_link_does_not_mark_unit_enabled(base_image):
    runner, result = start_runner(
        base_image, env={"FAKE_REQUIRED_BY_LINK_FAIL": KUBELET_UNITS[1]}
    )
    try:
        assert_exit_code(result, 1)
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(STATE_FILE)
        assert not runner.file_exists("/tmp/fake-systemctl/enabled-mnt-data.mount")
        for kubelet_unit in KUBELET_UNITS:
            requires_link = (
                f"/etc/systemd/system/{kubelet_unit}.requires/{UNIT_NAME}"
            )
            assert not runner.file_exists(requires_link)
    finally:
        runner.cleanup()


def test_install_rejects_successful_enable_with_missing_dependency_link(base_image):
    runner, result = start_runner(
        base_image, env={"FAKE_REQUIRED_BY_LINK_SKIP": KUBELET_UNITS[1]}
    )
    try:
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "required dependency link")
        assert_output_contains(result.stdout, "is missing or is not a symlink")
        assert not runner.file_exists("/tmp/fake-systemctl/enabled-mnt-data.mount")
        assert runner.file_exists(STATE_FILE)
        for kubelet_unit in KUBELET_UNITS:
            requires_link = (
                f"/etc/systemd/system/{kubelet_unit}.requires/{UNIT_NAME}"
            )
            assert not runner.file_exists(requires_link)
    finally:
        runner.cleanup()


def test_uninstall_does_not_disable_same_named_foreign_unit(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        enabled_marker = "/tmp/fake-systemctl/enabled-mnt-data.mount"
        assert runner.file_exists(enabled_marker)
        runner.container.exec_run(["rm", "-f", UNIT_FILE])

        foreign_fragment = "/usr/lib/systemd/system/mnt-data.mount"
        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {"FAKE_FRAGMENT_PATH": foreign_fragment},
        )
        assert exit_code == 1
        assert "refusing to disable absent owned unit" in output
        assert foreign_fragment in output
        assert runner.file_exists(enabled_marker)
        assert runner.file_exists(UNINSTALL_STATE_FILE)
    finally:
        runner.cleanup()


def test_failed_disable_retains_owned_unit_and_cleanup_receipt(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        enabled_marker = "/tmp/fake-systemctl/enabled-mnt-data.mount"
        assert runner.file_exists(enabled_marker)

        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {"FAKE_DISABLE_FAIL": "true"},
        )
        assert exit_code == 1
        assert "retaining its unit file and cleanup receipt" in output
        assert runner.file_exists(UNIT_FILE)
        assert runner.file_exists(enabled_marker)
        assert runner.file_exists(UNINSTALL_STATE_FILE)
    finally:
        runner.cleanup()


def test_failed_uninstall_check_retains_state_and_lock_for_retry(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        original_unit = runner.get_file_contents(UNIT_FILE)
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])
        uninstall_env = {"SKYHOOK_RESOURCE_ID": resource_id(generation=2)}

        exit_code, output = exec_mode(runner, "uninstall", uninstall_env)
        assert exit_code == 0, output
        setup = runner.container.exec_run(
            ["bash", "-c", f'printf "%s" "$UNIT_CONTENT" > {UNIT_FILE}'],
            environment={"UNIT_CONTENT": original_unit},
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "uninstall-check", uninstall_env)
        assert exit_code == 1
        assert "still exists" in output
        assert runner.file_exists(UNINSTALL_STATE_FILE)
        assert path_exists(runner, state_dir())
        assert runner.file_exists(lock_path())

        runner.container.exec_run(["rm", "-f", UNIT_FILE])
        exit_code, output = exec_mode(runner, "uninstall-check", uninstall_env)
        assert exit_code == 0, output
        assert not path_exists(runner, state_dir())
        assert not runner.file_exists(lock_path())
    finally:
        runner.cleanup()


def test_corrupt_uninstall_receipt_fails_closed_and_is_retained(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])
        uninstall_env = {"SKYHOOK_RESOURCE_ID": resource_id(generation=2)}
        exit_code, output = exec_mode(runner, "uninstall", uninstall_env)
        assert exit_code == 0, output

        setup = runner.container.exec_run(
            ["bash", "-c", f": > {UNINSTALL_STATE_FILE}"]
        )
        assert setup.exit_code == 0, setup.output.decode("utf-8", errors="replace")

        exit_code, output = exec_mode(runner, "uninstall-check", uninstall_env)
        assert exit_code == 1
        assert "state file" in output
        assert "is malformed" in output
        assert runner.file_exists(UNINSTALL_STATE_FILE)
        assert path_exists(runner, state_dir())
        assert runner.file_exists(lock_path())
    finally:
        runner.cleanup()


def test_uninstall_of_never_installed_package_is_clean_noop(base_image):
    runner, result = start_runner(base_image, env={"FAKE_SOURCE_FSTYPE": "ext4"})
    try:
        assert_exit_code(result, 1)
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)

        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])

        legacy_uninstall_env = {
            "SKYHOOK_RESOURCE_ID": resource_id(generation=2),
        }
        exit_code, output = exec_mode(runner, "uninstall", legacy_uninstall_env)
        assert exit_code == 0, output
        assert "nothing installed" in output
        assert not runner.file_exists(UNINSTALL_STATE_FILE)

        exit_code, output = exec_mode(
            runner,
            "uninstall-check",
            legacy_uninstall_env,
        )
        assert exit_code == 0, output
        assert "nothing installed" in output
        assert not path_exists(runner, state_dir())
        assert not runner.file_exists(lock_path())
    finally:
        runner.cleanup()


def test_uninstall_removes_persistence_without_live_unmount(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])
        legacy_uninstall_env = {
            "FAKE_TARGET_ACTIVE": "true",
            "SKYHOOK_RESOURCE_ID": resource_id(generation=2),
        }
        exit_code, output = exec_mode(
            runner,
            "uninstall",
            legacy_uninstall_env,
        )
        assert exit_code == 0, output
        assert "recycle the node" in output
        assert not runner.file_exists(UNIT_FILE)
        assert not runner.file_exists(STATE_FILE)
        assert runner.file_exists(UNINSTALL_STATE_FILE)

        # A surviving live mount may appear to systemd as a transient loaded
        # unit with no FragmentPath. An uninstall retry must not disable it by
        # name or mistake it for a foreign persistent definition.
        exit_code, output = exec_mode(
            runner,
            "uninstall",
            {**legacy_uninstall_env, "FAKE_LOAD_STATE": "loaded"},
        )
        assert exit_code == 0, output
        assert runner.file_exists(UNINSTALL_STATE_FILE)

        exit_code, output = exec_mode(
            runner,
            "uninstall-check",
            legacy_uninstall_env,
        )
        assert exit_code == 0, output
        assert "remains mounted until the node is recycled" in output
        assert not runner.file_exists(UNINSTALL_STATE_FILE)
        assert not path_exists(runner, state_dir())
        assert not runner.file_exists(lock_path())

        exit_code, output = exec_mode(
            runner,
            "uninstall-check",
            legacy_uninstall_env,
        )
        assert exit_code == 0, output
        assert "nothing installed" in output
        assert not runner.file_exists(lock_path())
    finally:
        runner.cleanup()


def test_uninstall_check_waits_for_root_gate_before_cleanup(base_image):
    runner, result = start_runner(base_image)
    try:
        assert_exit_code(result, 0)
        runner.container.exec_run(["rm", "-rf", "/skyhook-package/configmaps"])
        uninstall_env = {"SKYHOOK_RESOURCE_ID": resource_id(generation=2)}
        exit_code, output = exec_mode(runner, "uninstall", uninstall_env)
        assert exit_code == 0, output

        concurrent = runner.container.exec_run(
            [
                "bash",
                "-c",
                f"""
set -e
flock -s {STATE_ROOT} -c 'touch /tmp/root-gate-held; sleep 1' &
holder_pid=$!
for _ in $(seq 1 100); do
    [[ -e /tmp/root-gate-held ]] && break
    sleep 0.02
done
[[ -e /tmp/root-gate-held ]]
bash {SCRIPT} uninstall-check >/tmp/uninstall-check.out 2>&1 &
check_pid=$!
sleep 0.2
[[ -e {UNINSTALL_STATE_FILE} ]]
[[ -e {lock_path()} ]]
wait "${{holder_pid}}"
wait "${{check_pid}}"
cat /tmp/uninstall-check.out
[[ ! -e {state_dir()} ]]
[[ ! -e {lock_path()} ]]
""",
            ],
            environment={**BASE_ENV, **uninstall_env},
        )
        output = concurrent.output.decode("utf-8", errors="replace")
        assert concurrent.exit_code == 0, output
        assert "Persistent bind mount definition is removed" in output
    finally:
        runner.cleanup()
