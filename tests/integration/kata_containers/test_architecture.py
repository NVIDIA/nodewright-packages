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

"""Ensure foreign ELF payloads fail validation without executing them."""

from pathlib import Path
import struct
import subprocess
import sys

import pytest


CHECK = Path(__file__).resolve().parents[3] / "kata-containers/check-architecture.py"


@pytest.mark.parametrize("target,machine,accepted", [
    ("amd64", 62, True), ("arm64", 183, True),
    ("amd64", 183, False), ("arm64", 62, False),
])
def test_checks_actual_machine_instead_of_emulated_execution(tmp_path, target, machine, accepted):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", header, 18, machine)
    path = tmp_path / "kata-deploy"
    path.write_bytes(header)
    result = subprocess.run([sys.executable, str(CHECK), target, str(path)],
                            capture_output=True, text=True, check=False)
    assert (result.returncode == 0) is accepted
    if not accepted:
        assert "does not match" in result.stderr


@pytest.mark.parametrize("payload", [b"", b"#!/bin/sh\nexit 0\n", b"\x7fELF\x01\x01" + bytes(58)])
def test_rejects_missing_or_non_64_bit_elf_headers(tmp_path, payload):
    path = tmp_path / "kata-deploy"
    path.write_bytes(payload)
    result = subprocess.run([sys.executable, str(CHECK), "amd64", str(path)],
                            capture_output=True, text=True, check=False)
    assert result.returncode != 0
    assert "64-bit little-endian ELF" in result.stderr
