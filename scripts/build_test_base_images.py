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


"""Build prebuilt test base images for a package's TEST_MATRIX.

No-ops for packages that declare no tests/integration/<pkg>/test-base/Dockerfile,
so it is safe to run unconditionally from the Makefile test targets.
"""

import argparse
import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.helpers.base_images import (  # noqa: E402
    build_base_image,
    find_test_base_dockerfile,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, help="Package dir name, e.g. nvidia-tuned")
    parser.add_argument(
        "--base-image",
        default=None,
        help="Build only this base image instead of the whole TEST_MATRIX.",
    )
    parser.add_argument("--no-cache", action="store_true", help="Force a rebuild")
    args = parser.parse_args()

    package = args.package
    if find_test_base_dockerfile(package) is None:
        print(f"{package} declares no test base image; nothing to build.")
        return 0

    if args.base_image:
        base_images = [args.base_image]
    else:
        module_name = f"tests.integration.{package.replace('-', '_')}"
        try:
            module = importlib.import_module(module_name)
        except ImportError:
            print(f"No test module for {package}; nothing to build.")
            return 0

        base_images = [
            entry["base_image"] if isinstance(entry, dict) else entry
            for entry in getattr(module, "TEST_MATRIX", [])
        ]

    for base_image in base_images:
        print(f"Building test base image for {package} / {base_image} ...")
        build_base_image(package, base_image, no_cache=args.no_cache)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
