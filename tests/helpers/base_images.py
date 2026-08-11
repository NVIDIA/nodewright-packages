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


"""Prebuilt test base images.

A package opts in by adding `tests/integration/<pkg>/test-base/Dockerfile`, which
must accept a BASE_IMAGE build arg. Anything expensive and identical across tests
(installing a distro package, seeding fixtures) belongs there instead of in a
per-test `exec_run`. Packages that add no such file are unaffected.

These images are local-only. They are built on whichever machine runs the tests
and live only in that machine's Docker image store; nothing here pushes to or
pulls from a registry. See `assert_image_present` for the check that enforces it.
"""

import subprocess
from pathlib import Path
from typing import Optional

import docker

# Local-only tag prefix. These images are never pushed to a registry.
TEST_IMAGE_PREFIX = "nodewright-test-base"

_REPO_ROOT = Path(__file__).resolve().parents[2]

# Memoized so the daemon is asked once per image per process, not once per test.
_verified_images = set()


def _canonical(package: str) -> str:
    """Normalize a package name to its hyphenated package-directory form.

    Callers arrive with both spellings: the runner passes the package directory
    name (`nvidia-tuned`) while anything iterating `tests/integration/` sees the
    underscored test directory (`nvidia_tuned`). Without normalizing, the two
    would derive different image tags and the built image would never be found.
    """
    return package.replace("_", "-")


def find_test_base_dockerfile(package: str) -> Optional[Path]:
    """Return the package's test-base Dockerfile, or None if it does not opt in.

    Deliberately not named `test_*`: pytest would try to collect it as a test
    case anywhere this module's names are star-imported into a test module.
    """
    path = (
        _REPO_ROOT / "tests" / "integration" / _canonical(package).replace("-", "_")
        / "test-base" / "Dockerfile"
    )
    return path if path.is_file() else None


def baked_tag(package: str, base_image: str) -> str:
    """Local tag for a package's prebuilt image derived from `base_image`."""
    slug = base_image.replace(":", "-").replace("/", "-")
    return f"{TEST_IMAGE_PREFIX}:{_canonical(package)}-{slug}"


def resolve_base_image(package: str, base_image: str) -> str:
    """Map a matrix base image onto the package's prebuilt image, if it has one."""
    if find_test_base_dockerfile(package) is None:
        return base_image
    return baked_tag(package, base_image)


def assert_image_present(client, tag: str, package: str) -> None:
    """Fail fast if a prebuilt image is missing, instead of pulling from a registry.

    docker-py transparently pulls an unknown image. These images are local-only
    and exist in no registry, so that pull is always wrong: it is slow, it fails
    obscurely, and it is the only path by which this scheme could contact one.
    """
    if tag in _verified_images:
        return
    try:
        client.images.get(tag)
    except docker.errors.ImageNotFound:
        raise RuntimeError(
            f"Prebuilt test base image {tag!r} is not present locally.\n"
            f"These images are built on this machine and are never pushed or "
            f"pulled. Build it first:\n"
            f"    make test-base-images PACKAGE={package}"
        ) from None
    _verified_images.add(tag)


def build_base_image(package: str, base_image: str, no_cache: bool = False) -> Optional[str]:
    """Build one prebuilt image. Returns the tag, or None if the package opts out."""
    dockerfile = find_test_base_dockerfile(package)
    if dockerfile is None:
        return None

    tag = baked_tag(package, base_image)
    cmd = [
        "docker", "build",
        "--build-arg", f"BASE_IMAGE={base_image}",
        "--tag", tag,
    ]
    if no_cache:
        cmd.append("--no-cache")
    cmd.append(str(dockerfile.parent))

    subprocess.run(cmd, check=True)
    return tag
