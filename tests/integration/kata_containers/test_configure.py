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

"""Check package versions and architecture-specific deployment manifests."""

import json
from pathlib import Path
import subprocess
import sys

import pytest
import yaml


PACKAGE = Path(__file__).resolve().parents[3] / "kata-containers"


def configure(*args):
    return subprocess.run(
        [sys.executable, "-B", str(PACKAGE / "configure.py"), *args],
        capture_output=True, text=True, check=False, timeout=10,
    )


@pytest.mark.parametrize("version", ["4.3.1", "v4.3.1\n", "4.4.0-rc.1"])
def test_package_version_matches_kata_payload(tmp_path, version):
    config = json.loads((PACKAGE / "config.json").read_text())
    config["package_version"] = version.strip().removeprefix("v")
    template, payload, output = (tmp_path / name for name in ("config.json", "VERSION", "output.json"))
    template.write_text(json.dumps(config))
    payload.write_text(version)
    result = configure("--template", str(template), "--version-file", str(payload), "--output", str(output))
    assert result.returncode == 0, result.stderr
    generated = json.loads(output.read_text())
    assert generated["package_name"] == "kata-containers"
    assert generated["package_version"] == config["package_version"]


@pytest.mark.parametrize("version", ["latest", "", "4.3", "04.3.1", "4.3.1-01", "4.3.1+local", "4.3.0"])
def test_rejects_invalid_or_mismatched_payload_version(tmp_path, version):
    payload, output = tmp_path / "VERSION", tmp_path / "output.json"
    payload.write_text(version)
    result = configure("--version-file", str(payload), "--output", str(output))
    assert result.returncode != 0
    assert not output.exists()


def test_rejects_mismatched_expected_version(tmp_path):
    payload, output = tmp_path / "VERSION", tmp_path / "output.json"
    payload.write_text("4.3.1")
    result = configure("--version-file", str(payload), "--expected-version", "4.3.0", "--output", str(output))
    assert result.returncode != 0
    assert "differs" in result.stderr
    assert not output.exists()


def test_configuration_reconciles_at_same_version():
    config = json.loads((PACKAGE / "config.json").read_text())
    assert all(step["on_host"] for steps in config["modes"].values() for step in steps)
    assert config["expected_config_files"] == []
    assert config["modes"]["apply"][0]["arguments"] == ["prepare"]
    assert config["modes"]["config"][0]["arguments"] == ["install"]
    assert config["modes"]["config"][0]["idempotence"] is True


def test_shared_cpu_manifests():
    resource = yaml.safe_load((PACKAGE / "nodewright.yaml").read_text())
    runtime = yaml.safe_load((PACKAGE / "nvidia-cpu-runtimeclass.yaml").read_text())
    assert resource["kind"] == "NodeWright"
    assert resource["metadata"]["name"] == "kata-containers"
    assert runtime["kind"] == "RuntimeClass"
    assert runtime["metadata"]["name"] == "kata-containers-qemu-nvidia-cpu-runtime-rs"
    assert set(resource["spec"]["packages"]) == {"kata-containers"}
    package = resource["spec"]["packages"]["kata-containers"]
    assert "dependsOn" not in package
    assert "agentImageOverride" not in package
    assert package["version"] == json.loads((PACKAGE / "config.json").read_text())["package_version"]
    assert package["image"] == "ghcr.io/nvidia/nodewright-packages/kata-containers"
    env = {entry["name"]: entry.get("value") for entry in package["env"]}
    assert env["CONTAINERD_CONFIG_FILE_NAME"] == "config.toml"
    assert "CONTAINER_RUNTIME_VERSION" not in env
    assert env["DEBUG"] == "false"
    assert package["configInterrupts"] == {"*": {"type": "noop"}}
    assert runtime["handler"] == "kata-qemu-nvidia-cpu-runtime-rs"


def test_runtimeclass_uses_stable_pool_with_runtime_required_gate():
    resource = yaml.safe_load((PACKAGE / "nodewright.yaml").read_text())
    runtime = yaml.safe_load((PACKAGE / "nvidia-cpu-runtimeclass.yaml").read_text())
    selector = resource["spec"]["nodeSelectors"]
    assert selector["matchExpressions"] == [
        {"key": "kubernetes.io/arch", "operator": "In", "values": ["amd64", "arm64"]}
    ]
    assert runtime["scheduling"]["nodeSelector"] == selector["matchLabels"]
    assert resource["spec"]["runtimeRequired"] is True
    assert resource["spec"]["autoTaintNewNodes"] is True
    assert "tolerations" not in runtime["scheduling"]
    # Pausing or starting a rollout must not change RuntimeClass eligibility.
    assert not any("status_" in key for key in runtime["scheduling"]["nodeSelector"])


def test_native_preflight_and_staged_payload_cleanup_are_in_the_lifecycle():
    modes = json.loads((PACKAGE / "config.json").read_text())["modes"]
    for stage in ("apply", "upgrade"):
        assert modes[stage][0]["arguments"] == ["prepare"]
        assert modes[f"{stage}-check"][0]["arguments"] == ["check-prepared"]
    assert modes["post-interrupt"][0]["arguments"] == ["finalize"]
    assert modes["post-interrupt-check"][0]["arguments"] == ["check-finalized"]
