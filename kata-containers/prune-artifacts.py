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


"""Keep only the CPU runtime components listed by the pinned Kata payload."""

import json
from pathlib import Path
import re
import shutil
import sys


def prune(directory, target):
    arch = {"amd64": "x86_64", "arm64": "aarch64"}[target]
    manifest = json.loads((directory / "shim-components.json").read_text())
    components = manifest["shims"]["qemu-nvidia-cpu-runtime-rs"][arch]
    if not isinstance(components, list) or not components or any(
        not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name)
        for name in components
    ):
        raise ValueError("CPU component list must contain safe component names")
    required = {f"kata-static-{name}.tar.zst" for name in components}
    tarballs = directory / "tarballs"
    missing = sorted(name for name in required if not (tarballs / name).is_file())
    if missing:
        raise ValueError(f"missing CPU component tarballs: {missing}")
    for path in tarballs.glob("kata-static-*.tar.zst"):
        if path.name not in required:
            path.unlink()

    # This package always configures EROFS, never the nydus snapshotter.
    snapshotter = directory / "nydus-snapshotter"
    if snapshotter.exists():
        shutil.rmtree(snapshotter)


if __name__ == "__main__":
    try:
        prune(Path(sys.argv[2]), sys.argv[1])
    except (KeyError, ValueError, OSError) as error:
        sys.exit(f"cannot select CPU runtime artifacts: {error}")
