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
Tests for the configure_container_toolkit step (aks-h100, aks-any, oci-any). The
upgrade stage runs apply.sh, which test_lifecycle_modes.py enforces.

The test image has no NVIDIA container toolkit, so a stand-in nvidia-ctk and a
toolkit config are staged into the package and selected through the step's
NVIDIA_CTK and NVIDIA_CONTAINER_RUNTIME_CONFIG variables. The fixtures come from
an OKE GB300 node: config-hardened.toml is the file after real
`nvidia-ctk config --in-place` set both keys; config-stock.toml is the same file
with the keys at the toolkit's defaults.
"""

from pathlib import Path

import pytest

from tests.helpers.assertions import assert_exit_code, assert_output_contains
from tests.helpers.docker_test import DockerTestRunner


HERE = Path(__file__).parent
FIXTURES = HERE / "fixtures"
FAKE_CTK = "/skyhook-package/test/nvidia-ctk.sh"
CONFIG = "/skyhook-package/test/config.toml"

ENVVAR_LINE = "accept-nvidia-visible-devices-envvar-when-unprivileged = false"
MOUNTS_LINE = "accept-nvidia-visible-devices-as-volume-mounts = true"
# Unrelated content from the real file that must survive the edit.
PRESERVED_LINES = ['mode = "auto"', 'runtimes = ["runc", "crun"]', "[nvidia-container-cli]"]

TOOLKIT_COMBINATIONS = [
    {"service": "aks", "accelerator": "h100"},
    {"service": "aks", "accelerator": "any"},
    {"service": "oci", "accelerator": "any"},
]
TOOLKIT_IDS = ["aks-h100", "aks-any", "oci-any"]

TOOLKIT_ENV = {"NVIDIA_CTK": FAKE_CTK, "NVIDIA_CONTAINER_RUNTIME_CONFIG": CONFIG}


def _stage(tmp_path, config_text):
    """Return extra_files staging the fake nvidia-ctk and, optionally, a config."""
    files = [(HERE / "fake_nvidia_ctk.sh", "test/nvidia-ctk.sh")]
    if config_text is not None:
        config = tmp_path / "config.toml"
        config.write_text(config_text)
        files.append((config, "test/config.toml"))
    return files


def _fixture(name):
    return (FIXTURES / name).read_text()


def _exec(runner, script, env):
    """Run a lifecycle script again in the same container so state persists."""
    environment = {
        "SKYHOOK_DIR": "/skyhook-package",
        "STEP_ROOT": "/skyhook-package/skyhook_dir",
        "SKIP_SYSTEM_OPERATIONS": "true",
        **env,
    }
    result = runner.container.exec_run(
        ["/bin/bash", "-c", f"/skyhook-package/skyhook_dir/{script} 2>&1"],
        workdir="/skyhook-package",
        environment=environment,
    )
    return result.exit_code, result.output.decode("utf-8", errors="replace")


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS, ids=TOOLKIT_IDS)
def test_apply_hardens_stock_config(base_image, tmp_path, configmaps):
    """apply.sh sets both keys on a stock config, keeps the rest of the file, and apply_check.sh passes."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, _fixture("config-stock.toml")),
        )
        assert_exit_code(result, 0)

        lines = runner.get_file_contents(CONFIG).splitlines()
        assert ENVVAR_LINE in lines, lines
        assert MOUNTS_LINE in lines, lines
        for line in PRESERVED_LINES:
            assert line in lines, f"{line!r} was lost:\n" + "\n".join(lines)

        code, output = _exec(runner, "apply_check.sh", TOOLKIT_ENV)
        assert code == 0, output
        assert "container_toolkit_check: ok" in output, output
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[1:], ids=TOOLKIT_IDS[1:])
def test_apply_skips_already_hardened_config(base_image, tmp_path, configmaps):
    """On a config real nvidia-ctk already hardened, apply.sh changes nothing and apply_check.sh passes."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        hardened = _fixture("config-hardened.toml")
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, hardened),
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "already configured")
        assert runner.get_file_contents(CONFIG) == hardened

        code, output = _exec(runner, "apply_check.sh", TOOLKIT_ENV)
        assert code == 0, output
    finally:
        runner.cleanup()


@pytest.mark.parametrize(
    "config_text",
    [
        "accept-nvidia-visible-devices-envvar-when-unprivileged=false\naccept-nvidia-visible-devices-as-volume-mounts=true\n",
        "  accept-nvidia-visible-devices-envvar-when-unprivileged = false # hardened\n"
        "\taccept-nvidia-visible-devices-as-volume-mounts   =   true\n",
    ],
    ids=["no-spaces", "indented-and-commented"],
)
def test_check_accepts_equivalent_toml_formatting(base_image, tmp_path, config_text):
    """apply_check.sh accepts the keys written with other valid TOML spacing."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "oci", "accelerator": "any"},
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, config_text),
        )
        assert_exit_code(result, 0)
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[1:], ids=TOOLKIT_IDS[1:])
def test_apply_is_idempotent(base_image, tmp_path, configmaps):
    """A second apply.sh run short-circuits once both keys are set."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        first = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, _fixture("config-stock.toml")),
        )
        assert_exit_code(first, 0)

        code, output = _exec(runner, "apply.sh", TOOLKIT_ENV)
        assert code == 0, output
        assert "already configured" in output, output
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[1:], ids=TOOLKIT_IDS[1:])
def test_no_toolkit_config_is_a_noop(base_image, tmp_path, configmaps):
    """Without a toolkit config, apply.sh and apply_check.sh both succeed without changes."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, None),
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "no node toolkit to harden")
        assert not runner.file_exists(CONFIG)

        code, output = _exec(runner, "apply_check.sh", TOOLKIT_ENV)
        assert code == 0, output
        assert "nothing to check" in output, output
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[::2], ids=TOOLKIT_IDS[::2])
def test_apply_check_fails_on_stock_config(base_image, tmp_path, configmaps):
    """apply_check.sh fails while the config still has the toolkit's defaults."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        # aks-h100's check also requires configure_ib_rdma's files, so run its
        # toolkit check directly to isolate the toolkit keys.
        script = "steps_check/container_toolkit_check.sh" if configmaps["accelerator"] == "h100" else "apply_check.sh"
        result = runner.run_script(
            script=script,
            configmaps=configmaps,
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, _fixture("config-stock.toml")),
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout + result.stderr, "is missing")
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[1:], ids=TOOLKIT_IDS[1:])
def test_config_without_nvidia_ctk_is_skipped(base_image, tmp_path, configmaps):
    """With the toolkit config but no nvidia-ctk, apply.sh warns and skips, and apply_check.sh passes."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        stock = _fixture("config-stock.toml")
        no_ctk = {**TOOLKIT_ENV, "NVIDIA_CTK": "/nonexistent/nvidia-ctk"}
        result = runner.run_script(
            script="apply.sh",
            configmaps=configmaps,
            env_vars=no_ctk,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, stock),
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "was not found")
        assert runner.get_file_contents(CONFIG) == stock

        code, output = _exec(runner, "apply_check.sh", no_ctk)
        assert code == 0, output
        assert "nothing to check" in output, output
    finally:
        runner.cleanup()


@pytest.mark.parametrize("configmaps", TOOLKIT_COMBINATIONS[1:], ids=TOOLKIT_IDS[1:])
def test_post_interrupt_check_passes(base_image, configmaps):
    """The toolkit-only combinations declare no interrupt; post_interrupt_check.sh passes."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        result = runner.run_script(
            script="post_interrupt_check.sh",
            configmaps=configmaps,
            skip_system_operations=True,
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to check")
    finally:
        runner.cleanup()


def test_check_ignores_keys_inside_a_table(base_image, tmp_path):
    """Keys under a TOML table are not the top-level settings the toolkit reads; apply_check.sh fails."""
    runner = DockerTestRunner(package="nvidia-setup", base_image=base_image)
    try:
        config_text = (
            "accept-nvidia-visible-devices-envvar-when-unprivileged = true\n"
            "\n[nvidia-ctk]\n"
            "accept-nvidia-visible-devices-envvar-when-unprivileged = false\n"
            "accept-nvidia-visible-devices-as-volume-mounts = true\n"
        )
        result = runner.run_script(
            script="apply_check.sh",
            configmaps={"service": "oci", "accelerator": "any"},
            env_vars=TOOLKIT_ENV,
            skip_system_operations=True,
            extra_files=_stage(tmp_path, config_text),
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout + result.stderr, "is missing")
    finally:
        runner.cleanup()
