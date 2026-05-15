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
Tests for nvidia-setup aks-h100 combination (RDMA + memlock host setup).
"""

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


AKS_CONFIGMAPS = {"service": "aks", "accelerator": "h100"}

EXPECTED_FILES = {
    "/etc/modules-load.d/ib-umad.conf": ["ib_umad", "rdma_ucm"],
    "/etc/security/limits.d/99-ib-memlock.conf": [
        "* - memlock unlimited",
        "root - memlock unlimited",
    ],
    "/etc/systemd/system/containerd.service.d/memlock.conf": [
        "[Service]",
        "LimitMEMLOCK=infinity",
    ],
    "/etc/systemd/system/kubelet.service.d/memlock.conf": [
        "[Service]",
        "LimitMEMLOCK=infinity",
    ],
}


def test_apply_aks_h100_writes_files(base_image):
    """apply.sh on aks-h100 must write the four IB/memlock config files."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=AKS_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)

        for path, expected_lines in EXPECTED_FILES.items():
            contents = runner.get_file_contents(path)
            for line in expected_lines:
                assert line in contents, (
                    f"Expected line '{line}' missing from {path}. Contents:\n{contents}"
                )
    finally:
        runner.cleanup()
