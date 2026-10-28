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

"""Select the CPU payload from Kata's architecture-specific component catalog."""

import json
from pathlib import Path
import subprocess
import sys

import pytest


PRUNE = Path(__file__).resolve().parents[3] / "kata-containers/prune-artifacts.py"


@pytest.mark.parametrize("target,arch", [("amd64", "x86_64"), ("arm64", "aarch64")])
def test_only_required_cpu_components_are_retained(tmp_path, target, arch):
    (tmp_path / "shim-components.json").write_text(json.dumps({"shims": {
        "qemu-nvidia-cpu-runtime-rs": {arch: ["shim-v2-rust", "qemu", "image-nvidia-gpu"]},
        "qemu-nvidia-gpu-tdx-runtime-rs": {arch: ["qemu-tdx"]},
    }}))
    tarballs = tmp_path / "tarballs"
    tarballs.mkdir()
    for component in ("shim-v2-rust", "qemu", "image-nvidia-gpu", "qemu-tdx", "shim-v2-go"):
        (tarballs / f"kata-static-{component}.tar.zst").write_bytes(b"payload")
    (tmp_path / "VERSION").write_text("4.3.1")
    (tmp_path / "nydus-snapshotter").mkdir()
    (tmp_path / "nydus-snapshotter/nydus-snapshotter").write_bytes(b"unused")
    result = subprocess.run([sys.executable, str(PRUNE), target, str(tmp_path)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert sorted(path.name for path in tarballs.iterdir()) == [
        "kata-static-image-nvidia-gpu.tar.zst", "kata-static-qemu.tar.zst", "kata-static-shim-v2-rust.tar.zst"]
    assert (tmp_path / "VERSION").read_text() == "4.3.1"
    assert not (tmp_path / "nydus-snapshotter").exists()


@pytest.mark.parametrize("components", [[], ["missing"], ["../escape"], [None]])
def test_bad_or_incomplete_catalog_fails_before_pruning(tmp_path, components):
    (tmp_path / "shim-components.json").write_text(json.dumps({"shims": {
        "qemu-nvidia-cpu-runtime-rs": {"aarch64": components}}}))
    tarballs = tmp_path / "tarballs"
    tarballs.mkdir()
    sentinel = tarballs / "kata-static-sentinel.tar.zst"
    sentinel.write_bytes(b"keep on failure")
    result = subprocess.run([sys.executable, str(PRUNE), "arm64", str(tmp_path)], capture_output=True, text=True)
    assert result.returncode != 0
    assert "cannot select CPU runtime artifacts" in result.stderr
    assert sentinel.exists()
