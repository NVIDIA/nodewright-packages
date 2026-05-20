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
Tests for tuning update_settings_uninstall.sh script.

The uninstall script removes drop-in files written by update_settings.sh.
The systemd drop-in path uses a glob (`/etc/systemd/system/*.d/...`) so on a
node where no matching files exist the glob can either expand to nothing or
be passed literally to `rm`. Under `set -e` this used to abort the whole
uninstall. These tests guard the `rm -f` form that tolerates both cases.
"""

from tests.helpers.assertions import (
    assert_exit_code,
    assert_file_exists,
)
from tests.helpers.docker_test import DockerTestRunner


SKYHOOK_RESOURCE_ID = "1_tuning_1.1.4"
PACKAGE_NAME_FROM_RESOURCE_ID = "tuning"
DROP_IN_FILENAME = f"999-{PACKAGE_NAME_FROM_RESOURCE_ID}-tuning.conf"


def test_uninstall_succeeds_when_no_service_drop_in_files_exist(base_image):
    """Regression: uninstall must not fail when the systemd drop-in glob matches nothing.

    Previously the script ran
        rm /etc/systemd/system/*.d/999-${package_name}-tuning.conf
    On a clean node with no matching files, bash leaves the glob literal and
    `rm` exits non-zero, which trips `set -e` and aborts the whole uninstall.
    The fix is `rm -f`, which silently tolerates missing operands.
    """
    runner = DockerTestRunner(package="tuning", base_image=base_image)
    try:
        result = runner.run_script(
            script="update_settings_uninstall.sh",
            env_vars={"SKYHOOK_RESOURCE_ID": SKYHOOK_RESOURCE_ID},
        )
        assert_exit_code(result, 0)
        # No literal-glob diagnostic should appear in the output.
        assert "No such file or directory" not in result.stdout, result.stdout
        assert "*.d/" not in result.stdout, result.stdout
    finally:
        runner.cleanup()


def test_uninstall_removes_existing_service_drop_in_file(base_image):
    """Happy path: uninstall removes the drop-in file when one is present.

    Seeds /etc/systemd/system/containerd.service.d/999-tuning-tuning.conf in
    the container before running the uninstall script, then asserts the file
    is gone and the script exited cleanly.
    """
    runner = DockerTestRunner(package="tuning", base_image=base_image)
    try:
        result = runner.run_script(
            script="update_settings_uninstall.sh",
            env_vars={"SKYHOOK_RESOURCE_ID": SKYHOOK_RESOURCE_ID},
        )
        assert_exit_code(result, 0)

        drop_in_dir = "/etc/systemd/system/containerd.service.d"
        drop_in_path = f"{drop_in_dir}/{DROP_IN_FILENAME}"
        seed = runner.container.exec_run(
            ["/bin/bash", "-c", f"mkdir -p {drop_in_dir} && echo '[Service]' > {drop_in_path}"],
            workdir="/",
        )
        assert seed.exit_code == 0, seed.output.decode("utf-8", errors="replace")
        assert_file_exists(runner, drop_in_path)

        uninstall_path = "/skyhook-package/skyhook_dir/update_settings_uninstall.sh"
        exec_result = runner.container.exec_run(
            ["/bin/bash", "-c", f"{uninstall_path} 2>&1"],
            workdir="/skyhook-package",
            environment={
                "SKYHOOK_DIR": "/skyhook-package",
                "STEP_ROOT": "/skyhook-package/skyhook_dir",
                "SKYHOOK_RESOURCE_ID": SKYHOOK_RESOURCE_ID,
            },
        )
        assert exec_result.exit_code == 0, exec_result.output.decode("utf-8", errors="replace")
        assert not runner.file_exists(drop_in_path), (
            f"Expected {drop_in_path} to be removed by uninstall, but it still exists"
        )
    finally:
        runner.cleanup()
