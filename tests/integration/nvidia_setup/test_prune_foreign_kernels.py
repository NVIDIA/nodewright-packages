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
Tests for prune_foreign_kernels in utilities.sh.

prune_foreign_kernels purges every installed kernel except the running one (plus
optional keep-extra versions) so out-of-tree DKMS modules (EFA) are only built
against the booted/target kernel. On a 64k running kernel it also purges the 4k
page-size sibling flavour's meta packages, otherwise apt upgrades the meta and
re-pulls a 4k kernel that EFA 3.0.0 cannot build against on arm64.

The harness mocks uname/dpkg-query and runs the function in SKIP_SYSTEM_OPERATIONS
dry-run, so these assert the resolved purge set, not the apt purge itself.
"""

from pathlib import Path

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
    assert_output_not_contains,
)
from tests.helpers.docker_test import DockerTestRunner

# Test script lives with tests and is copied into the package at run time.
_PRUNE_SCRIPT_SOURCE = Path(__file__).parent / "run_prune_foreign_kernels_test.sh"
_PRUNE_SCRIPT_DEST = "skyhook_dir/steps/run_prune_foreign_kernels_test.sh"


def _run_prune(runner, running, installed_packages, keep_extra=""):
    """Run the prune harness; return the TestResult."""
    env = {
        "RUNNING_KERNEL": running,
        "INSTALLED_PACKAGES": " ".join(installed_packages),
    }
    if keep_extra:
        env["KEEP_EXTRA"] = keep_extra
    return runner.run_script(
        script="steps/run_prune_foreign_kernels_test.sh",
        configmaps={},
        env_vars=env,
        extra_files=[(_PRUNE_SCRIPT_SOURCE, _PRUNE_SCRIPT_DEST)],
    )


def test_prunes_stray_kernel_and_sibling_metas():
    """Stray 1017-aws concrete kernel and the 4k sibling metas are purged; the running 64k kernel is kept."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = _run_prune(
            runner,
            running="6.17.0-1019-aws-64k",
            installed_packages=[
                "linux-image-6.17.0-1019-aws-64k",
                "linux-image-6.17.0-1017-aws",
                "linux-headers-6.17.0-1017-aws",
                "linux-modules-6.17.0-1017-aws",
                "linux-aws",
                "linux-image-aws",
                "linux-headers-aws",
            ],
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "linux-image-6.17.0-1017-aws")
        # The 4k sibling meta must be purged too, or apt re-pulls a 4k kernel.
        assert_output_contains(result.stdout, "linux-image-aws")
        assert_output_contains(result.stdout, "linux-aws")
        # The running kernel and any package not installed are never purged.
        assert_output_not_contains(result.stdout, "linux-image-6.17.0-1019-aws-64k")
        assert_output_not_contains(result.stdout, "linux-tools-aws")
    finally:
        runner.cleanup()


def test_prunes_4k_sibling_kernel_and_meta_regression():
    """Regression: after the meta upgraded to the same ABI, the 4k 1019-aws kernel and its meta must both be purged."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = _run_prune(
            runner,
            running="6.17.0-1019-aws-64k",
            installed_packages=[
                "linux-image-6.17.0-1019-aws-64k",
                "linux-image-6.17.0-1019-aws",
                "linux-headers-6.17.0-1019-aws",
                "linux-modules-6.17.0-1019-aws",
                "linux-aws",
                "linux-image-aws",
                "linux-headers-aws",
            ],
        )
        assert_exit_code(result, 0)
        # Exact match, not prefix: the 4k 1019-aws kernel is foreign to the 64k running kernel.
        assert_output_contains(result.stdout, "linux-image-6.17.0-1019-aws")
        assert_output_contains(result.stdout, "linux-image-aws")
        # The 64k running kernel is kept.
        assert_output_not_contains(result.stdout, "linux-image-6.17.0-1019-aws-64k")
    finally:
        runner.cleanup()


def test_clean_64k_only_is_a_no_op():
    """When only the running 64k kernel and its own 64k metas are installed there is nothing to prune."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = _run_prune(
            runner,
            running="6.17.0-1019-aws-64k",
            installed_packages=[
                "linux-image-6.17.0-1019-aws-64k",
                "linux-image-aws-64k",
                "linux-headers-aws-64k",
                "linux-aws-64k",
            ],
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to prune")
        # The running flavour's own metas must never be purged.
        assert_output_not_contains(result.stdout, "linux-image-aws-64k")
    finally:
        runner.cleanup()


def test_install_pass_keep_extra_preserves_unbooted_target():
    """Install-pass case: running the old 4k kernel, keep the just-installed 64k target; prune nothing (no 64k sibling logic while on 4k)."""
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = _run_prune(
            runner,
            running="6.17.0-1017-aws",
            installed_packages=[
                "linux-image-6.17.0-1017-aws",
                "linux-image-6.17.0-1019-aws-64k",
                "linux-aws",
                "linux-image-aws",
            ],
            keep_extra="6.17.0-1019-aws-64k",
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to prune")
        # The not-yet-booted target must be kept.
        assert_output_not_contains(result.stdout, "linux-image-6.17.0-1019-aws-64k")
    finally:
        runner.cleanup()
