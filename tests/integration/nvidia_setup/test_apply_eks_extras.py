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

"""Integration tests for the dgxcloud_aws_eks-derived steps wired into eks-h100/eks-gb200."""

import pytest

from tests.helpers.assertions import assert_exit_code
from tests.helpers.docker_test import DockerTestRunner


EKS_H100_CONFIGMAPS = {"service": "eks", "accelerator": "h100"}
EKS_GB200_CONFIGMAPS = {"service": "eks", "accelerator": "gb200"}


SYSCTL_FILE = "/etc/sysctl.d/999-nvidia-tuning.conf"
SYSCTL_EXPECTED_LINES = [
    "fs.inotify.max_user_instances=65535",
    "fs.inotify.max_user_watches=524288",
]


@pytest.mark.parametrize("configmaps", [EKS_H100_CONFIGMAPS, EKS_GB200_CONFIGMAPS])
def test_system_node_settings_writes_sysctl_file(base_image, configmaps):
    """system_node_settings must write /etc/sysctl.d/999-nvidia-tuning.conf on eks-* combos."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)

        contents = runner.get_file_contents(SYSCTL_FILE)
        for line in SYSCTL_EXPECTED_LINES:
            assert line in contents, (
                f"Expected line '{line}' missing from {SYSCTL_FILE}. Contents:\n{contents}"
            )
    finally:
        runner.cleanup()


CLOUD_INIT_FILES = {
    "/etc/cloud/cloud.cfg.d/99-dgxcloud.cfg": ["datasource:", "Ec2:", "max_wait: 300", "timeout: 30"],
    "/etc/systemd/system/cloud-init-local.service.d/10-wait-for-net-device.conf": [
        "Requires=dev-ec2imds.device",
        "After=dev-ec2imds.device",
    ],
    "/etc/udev/rules.d/10-ec2imds.rules": [
        'ACTION!="remove"',
        'SUBSYSTEM=="net"',
        'DRIVERS=="ena|vif"',
    ],
}


@pytest.mark.parametrize("configmaps", [EKS_H100_CONFIGMAPS, EKS_GB200_CONFIGMAPS])
def test_cloud_init_cfg_writes_files(base_image, configmaps):
    """cloud_init_cfg must write the EC2 IMDS/cloud-init drop-in files on eks-* combos."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)

        for path, expected_lines in CLOUD_INIT_FILES.items():
            contents = runner.get_file_contents(path)
            for line in expected_lines:
                assert line in contents, (
                    f"Expected line '{line}' missing from {path}. Contents:\n{contents}"
                )
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", [EKS_H100_CONFIGMAPS, EKS_GB200_CONFIGMAPS])
def test_apply_check_eks_passes_after_apply(base_image, configmaps):
    """apply_check.sh on eks-* must pass once the new steps have written their files."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        apply_result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            skip_system_operations=True,
        )
        assert_exit_code(apply_result, 0)

        container = runner.container
        check_cmd = "/skyhook-package/skyhook_dir/apply_check.sh 2>&1"
        exec_result = container.exec_run(
            ["/bin/bash", "-c", check_cmd],
            workdir="/skyhook-package",
            environment={
                "SKYHOOK_DIR": "/skyhook-package",
                "STEP_ROOT": "/skyhook-package/skyhook_dir",
                "SKIP_SYSTEM_OPERATIONS": "true",
            },
        )
        check_output = exec_result.output.decode("utf-8", errors="replace")
        assert exec_result.exit_code == 0, (
            f"apply_check.sh failed (exit {exec_result.exit_code})\noutput: {check_output}"
        )
    finally:
        runner.cleanup()


def test_apply_eks_skips_lustre_by_default(base_image):
    """Without SETUP_LUSTRE=true, install-lustre.sh must NOT be invoked on eks-*."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=EKS_H100_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert "Installing lustre from AWS repo" not in result.stdout, (
            f"install-lustre.sh ran without SETUP_LUSTRE=true. stdout:\n{result.stdout}"
        )
    finally:
        runner.cleanup()


def test_apply_eks_runs_lustre_when_opted_in(base_image):
    """With SETUP_LUSTRE=true, install-lustre.sh must be invoked on eks-*."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=EKS_H100_CONFIGMAPS,
            env_vars={"SETUP_LUSTRE": "true"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert "Installing lustre from AWS repo" in result.stdout, (
            f"install-lustre.sh did not run with SETUP_LUSTRE=true. stdout:\n{result.stdout}"
        )
    finally:
        runner.cleanup()
