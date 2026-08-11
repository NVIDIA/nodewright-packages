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


"""Emit the GitHub Actions test shard matrix for a set of packages.

A package shards only if its tests/integration/<pkg>/__init__.py sets
SHARD_BY_BASE_IMAGE = True. Everything else gets a single job, because extra
shards cost more in fixed per-job setup (~60-90s of checkout, venv, pip, image
pulls) than they save for a suite that already finishes in under a minute.

Standard library only, and reads the matrix with `ast` rather than importing it,
so the CI job that calls this needs no venv and no test dependencies.
"""

import argparse
import ast
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _read_init(package: str):
    init = REPO_ROOT / "tests" / "integration" / package.replace("-", "_") / "__init__.py"
    return ast.parse(init.read_text()) if init.is_file() else None


def _assigned(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == name for t in node.targets
        ):
            return ast.literal_eval(node.value)
    return None


def shards_for(package: str) -> list:
    """Return the shard entries for one package (possibly just a single job)."""
    tree = _read_init(package)
    if tree is None:
        # No test directory: still emit one job so the workflow reports on it.
        return [{"package": package, "shard": "all", "args": "", "base_image": ""}]

    entries = _assigned(tree, "TEST_MATRIX") or []
    images = [e["base_image"] if isinstance(e, dict) else e for e in entries]

    if not _assigned(tree, "SHARD_BY_BASE_IMAGE") or len(images) < 2:
        return [{"package": package, "shard": "all", "args": "", "base_image": ""}]

    shards = [
        {
            "package": package,
            "shard": image.replace(":", "-").replace("/", "-"),
            "args": f"--base-image {image} --matrix-scope matrix",
            "base_image": image,
        }
        for image in images
    ]
    # The tests that are not parametrized by base_image carry no image suffix in
    # their IDs, so they need their own explicitly-selected shard or they would
    # simply never run.
    shards.append(
        {
            "package": package,
            "shard": "pinned-image",
            "args": "--matrix-scope no-matrix",
            "base_image": "",
        }
    )
    return shards


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="+", help="Package directory names")
    args = parser.parse_args()
    print(json.dumps([s for p in args.packages for s in shards_for(p)]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
