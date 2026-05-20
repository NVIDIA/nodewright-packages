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
Tests for tuning update_settings_check.sh script.

The check script verifies that what update_settings.sh wrote into
/etc/sysctl.d/999-${package_name}-tuning.conf matches the configmap. The
historical implementation iterated every line of the configmap (including
blank lines and comments) and ran `grep -c "${line}" target`, which had
two bugs:

1. `grep` (without `-F`) treated the line as a regex, so configmap content
   with bracket metacharacters (e.g. the H100 inference profile's header
   `# H100 inference – sysctl. Mirrors nvidia-base + nvidia-h100-inference [sysctl].`)
   broke the search and made check report `not in sysctl: ...` even though
   update_settings.sh had copied the configmap verbatim.
2. Comments / blank lines were not skipped, so naive doc headers became
   load-bearing.

These tests guard the fix that skips comments/blanks before iterating and
uses `grep -F` for literal-string matching.
"""

from tests.helpers.assertions import assert_exit_code
from tests.helpers.docker_test import DockerTestRunner


SKYHOOK_RESOURCE_ID = "1_tuning_1.1.5"
PACKAGE_NAME_FROM_RESOURCE_ID = "tuning"
SYSCTL_DROP_IN = f"/etc/sysctl.d/999-{PACKAGE_NAME_FROM_RESOURCE_ID}-tuning.conf"

# Reproduces nvidia-tuning-gke/profiles/h100/inference/sysctl.conf exactly,
# including the comment header containing "[sysctl]" that broke the check
# script in production.
H100_INFERENCE_SYSCTL = (
    "# H100 inference – sysctl. Mirrors nvidia-base + nvidia-h100-inference [sysctl].\n"
    "net.ipv4.conf.all.arp_announce = 2\n"
    "net.ipv4.conf.default.arp_announce = 2\n"
    "net.ipv4.conf.all.arp_ignore = 1\n"
    "net.ipv4.conf.default.arp_ignore = 1\n"
    "vm.swappiness=1\n"
)


def _start_container_with_configmaps(base_image, sysctl_conf):
    """Bring up a runner container with a sysctl.conf configmap in place.

    We invoke update_settings_uninstall.sh as a no-op bootstrap (idempotent
    and exits 0 on a clean container) just to get the runner's container
    started with /skyhook-package mounted and the configmap seeded; we
    can't run update_settings.sh directly because it calls `sysctl -p`,
    which fails for namespaced sysctls inside a non-privileged container.
    """
    runner = DockerTestRunner(package="tuning", base_image=base_image)
    bootstrap = runner.run_script(
        script="update_settings_uninstall.sh",
        configmaps={"sysctl.conf": sysctl_conf},
        env_vars={"SKYHOOK_RESOURCE_ID": SKYHOOK_RESOURCE_ID},
    )
    assert_exit_code(bootstrap, 0)
    return runner


def _simulate_install_copy(runner):
    """Simulate the cp step of update_settings.sh into /etc/sysctl.d/."""
    seed = runner.container.exec_run(
        [
            "/bin/bash",
            "-c",
            f"cp /skyhook-package/configmaps/sysctl.conf {SYSCTL_DROP_IN}",
        ],
        workdir="/",
    )
    assert seed.exit_code == 0, seed.output.decode("utf-8", errors="replace")


def _run_check(runner):
    """Execute update_settings_check.sh in the existing runner container."""
    return runner.container.exec_run(
        ["/bin/bash", "-c", "/skyhook-package/skyhook_dir/update_settings_check.sh 2>&1"],
        workdir="/skyhook-package",
        environment={
            "SKYHOOK_DIR": "/skyhook-package",
            "STEP_ROOT": "/skyhook-package/skyhook_dir",
            "SKYHOOK_RESOURCE_ID": SKYHOOK_RESOURCE_ID,
        },
    )


def test_check_succeeds_with_h100_style_comment_containing_brackets(base_image):
    """Regression: check must not fail on a configmap whose comment header contains
    bracket-style regex metacharacters such as the H100 inference profile's
    `[sysctl]` tag.

    Pre-fix, the check script ran `grep -c "${line}" target` for every line of
    the configmap, including comments. The `[sysctl]` substring was parsed as
    a character class and the search missed the literal line that
    update_settings.sh had just copied verbatim, so check reported
    `not in sysctl: # H100 inference ...` and exited 1.
    """
    runner = _start_container_with_configmaps(base_image, H100_INFERENCE_SYSCTL)
    try:
        _simulate_install_copy(runner)
        result = _run_check(runner)
        output = result.output.decode("utf-8", errors="replace")
        assert result.exit_code == 0, f"check exited non-zero:\n{output}"
        assert "not in sysctl:" not in output, output
    finally:
        runner.cleanup()


def test_check_still_reports_genuinely_missing_sysctl_assignment(base_image):
    """Sanity: the fix must not silently pass when a real sysctl assignment is
    actually missing from the drop-in file. Seeds a drop-in that's missing
    `vm.swappiness=1` and asserts check fails with the expected diagnostic.
    """
    runner = _start_container_with_configmaps(base_image, H100_INFERENCE_SYSCTL)
    try:
        # Seed a drop-in that contains every line EXCEPT vm.swappiness=1.
        truncated = "\n".join(
            line for line in H100_INFERENCE_SYSCTL.splitlines() if "vm.swappiness" not in line
        ) + "\n"
        seed = runner.container.exec_run(
            [
                "/bin/bash",
                "-c",
                f"cat > {SYSCTL_DROP_IN} <<'EOF'\n{truncated}EOF",
            ],
            workdir="/",
        )
        assert seed.exit_code == 0, seed.output.decode("utf-8", errors="replace")

        result = _run_check(runner)
        output = result.output.decode("utf-8", errors="replace")
        assert result.exit_code == 1, f"check should have failed:\n{output}"
        assert "not in sysctl: vm.swappiness=1" in output, output
        # Crucially, the comment line must not be reported as missing.
        assert "not in sysctl: # H100" not in output, output
    finally:
        runner.cleanup()
