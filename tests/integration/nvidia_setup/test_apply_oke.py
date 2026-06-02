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

"""Tests for nvidia-setup oke flavor."""
from pathlib import Path

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


def test_oke_listed_in_supported():
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "invalid", "accelerator": "invalid"},
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "oke-h100")
        assert_output_contains(result.stdout, "oke-gb200")
    finally:
        runner.cleanup()


def test_resolve_full_kernel_oracle_unchanged():
    wrapper = Path(__file__).parent / "fixtures" / "resolve_kernel_wrapper.sh"
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script="_test_resolve_kernel.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            extra_files=[(wrapper, "skyhook_dir/_test_resolve_kernel.sh")],
            script_args=["6.8.0-1041-oracle"],
        )
        assert_exit_code(result, 0)
        assert "6.8.0-1041-oracle" in result.stdout
        assert "-aws" not in result.stdout
    finally:
        runner.cleanup()


def test_oke_install_kernel_only_skips_actual_install(base_image):
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps={"service": "oke", "accelerator": "gb200"},
            env_vars={"NVIDIA_SETUP_INSTALL_KERNEL": "true"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Skipping kernel install for test environment")
    finally:
        runner.cleanup()


def test_oke_chrony_uses_oci_ntp(base_image):
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="steps/configure-chrony.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        # chrony.conf should reference the OCI IMDS NTP server
        assert "169.254.169.254" in runner.get_file_contents("/etc/chrony/chrony.conf")
    finally:
        runner.cleanup()


def test_oke_install_doca_skips_system_ops(base_image):
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="steps/install_doca.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            script_args=["3.3.0"],
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Skipping DOCA install")
    finally:
        runner.cleanup()


def test_oke_install_oci_hpc_packages_skips(base_image):
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="steps/install_oci_hpc_packages.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Skipping OCI HPC package install")
    finally:
        runner.cleanup()


def test_oke_configure_hpc_networking_drops_files(base_image):
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="steps/configure_hpc_networking.sh",
            configmaps={"service": "oke", "accelerator": "h100"},
            script_args=["h100"],
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        for path in [
            "/etc/udev/rules.d/99-oci-network-mlx.rules",
            "/usr/bin/oci-create-vfs",
            "/usr/bin/oci-sriov-vf-config",
            "/etc/oracle-cloud-agent/plugins/oci-hpc/oci-hpc-configure/rdma_network.json",
        ]:
            assert runner.file_exists(path), f"missing {path}"
    finally:
        runner.cleanup()
