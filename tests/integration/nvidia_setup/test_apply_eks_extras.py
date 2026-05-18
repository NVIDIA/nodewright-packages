#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

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
