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


def test_apply_check_aks_h100_passes_after_apply(base_image):
    """apply_check.sh on aks-h100 must pass once configure_ib_rdma has written the files."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        # First run apply.sh to write the files.
        apply_result = runner.run_script(
            script="apply.sh",
            configmaps=AKS_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(apply_result, 0)

        # Reuse the same container for apply_check.sh so /etc files persist
        container = runner.container
        check_cmd = "/skyhook-package/skyhook_dir/apply_check.sh 2>&1"
        exec_result = container.exec_run(
            ["/bin/bash", "-c", check_cmd],
            workdir="/skyhook-package",
            environment={
                "SKYHOOK_DIR": "/skyhook-package",
                "STEP_ROOT": "/skyhook-package/skyhook_dir",
                "SKIP_SYSTEM_OPERATIONS": "true",
            }
        )
        check_output = exec_result.output.decode('utf-8', errors='replace')
        assert exec_result.exit_code == 0, (
            f"apply_check.sh failed with exit code {exec_result.exit_code}\n"
            f"output: {check_output}"
        )
    finally:
        runner.cleanup()


def test_apply_check_aks_h100_fails_when_files_missing(base_image):
    """apply_check.sh on aks-h100 must fail when configure_ib_rdma has not run."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        # Skip apply.sh; run apply_check.sh directly.
        check_result = runner.run_script(
            script="apply_check.sh",
            configmaps=AKS_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(check_result, 1)
        assert_output_contains(check_result.stdout, "missing")
    finally:
        runner.cleanup()


def test_post_interrupt_check_aks_h100_skips_under_skip_system_ops(base_image):
    """post_interrupt_check.sh on aks-h100 should exit 0 under SKIP_SYSTEM_OPERATIONS,
    since systemctl/LimitMEMLOCK cannot be checked inside the test container."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="post_interrupt_check.sh",
            configmaps=AKS_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "skipping memlock check")
    finally:
        runner.cleanup()


def test_post_interrupt_check_eks_h100_still_runs_kernel_check(base_image):
    """Regression: EKS combos must still route to kernel_install_check.sh.
    Without NVIDIA_SETUP_INSTALL_KERNEL=true, that check no-ops (exit 0)."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="post_interrupt_check.sh",
            configmaps={"service": "eks", "accelerator": "h100"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()


def test_apply_aks_h100_idempotent(base_image):
    """Two consecutive apply.sh runs in the same container short-circuit on the second."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        first = runner.run_script(
            script="apply.sh",
            configmaps=AKS_CONFIGMAPS,
            skip_system_operations=True,
        )
        assert_exit_code(first, 0)

        # Re-execute apply.sh inside the same container so state from the first
        # run (/etc/... files) persists.
        exec_result = runner.container.exec_run(
            ["/bin/bash", "-c", "/skyhook-package/skyhook_dir/apply.sh 2>&1"],
            workdir="/skyhook-package",
            environment={
                "SKYHOOK_DIR": "/skyhook-package",
                "SKIP_SYSTEM_OPERATIONS": "true",
            }
        )
        output = exec_result.output.decode("utf-8", errors="replace")
        assert exec_result.exit_code == 0, f"second run failed: {output}"
        assert "already configured" in output, f"missing short-circuit message:\n{output}"
    finally:
        runner.cleanup()
