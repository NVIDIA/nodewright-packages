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


"""Meta-tests: the CI shards must exactly partition the suite.

Guards against the `-k <image>` trap. Test IDs only carry an image suffix when
the test is parametrized by base_image, so selecting a shard with `-k ubuntu-24.04`
silently drops every test pinned to a fixed image. Measured: `-k "ubuntu-24.04"`
selects 37 of nvidia_tuned's 270 tests, dropping the 85 pinned-image ones.

These tests only collect (`--collect-only`); they start no containers.
"""

import pathlib
import subprocess
import sys

import pytest

from tests.integration.nvidia_tuned import TEST_MATRIX

PACKAGE_DIR = "tests/integration/nvidia_tuned"
IMAGES = [e["base_image"] if isinstance(e, dict) else e for e in TEST_MATRIX]


def _collected(*args: str) -> int:
    """Return how many tests pytest actually selects for the given args.

    Counts emitted test IDs rather than parsing the summary line: with a
    deselection in play pytest prints "37/122 tests collected", where the number
    that matters is the numerator. Counting `::` lines avoids that ambiguity.
    """
    result = subprocess.run(
        [sys.executable, "-m", "pytest", PACKAGE_DIR, "--collect-only", "-q", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    # pytest exits 5 for "no tests collected", which is a legitimate answer of 0.
    if result.returncode == 5:
        return 0
    if result.returncode != 0:
        raise AssertionError(
            f"pytest --collect-only failed ({result.returncode}) for args {args!r}:\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return sum(1 for line in result.stdout.splitlines() if "::" in line)


@pytest.mark.timeout(600)
def test_shards_partition_the_suite_exactly():
    total = _collected()
    matrix_total = sum(
        _collected("--base-image", image, "--matrix-scope", "matrix") for image in IMAGES
    )
    no_matrix_total = _collected("--matrix-scope", "no-matrix")

    assert matrix_total + no_matrix_total == total, (
        f"shards cover {matrix_total + no_matrix_total} tests but the suite has "
        f"{total}; some tests would silently never run in CI"
    )


@pytest.mark.timeout(600)
def test_no_matrix_shard_is_not_empty():
    """The tests pinned to a fixed image must land in some shard."""
    assert _collected("--matrix-scope", "no-matrix") > 0


@pytest.mark.timeout(600)
def test_selecting_shards_with_dash_k_would_drop_tests():
    """Document why --base-image exists rather than -k.

    If this ever stops being true, the -k trap is gone and this guard can go.
    """
    total = _collected()
    via_k = sum(_collected("-k", image.replace(":", "-")) for image in IMAGES)
    assert via_k < total, (
        "-k now covers the whole suite; the sharding options may be unnecessary"
    )


def test_only_opted_in_packages_are_sharded():
    """Sharding is opt-in. A package without SHARD_BY_BASE_IMAGE gets one job,
    because extra shards cost more in fixed per-job setup than they save."""
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from scripts.test_shards import shards_for

    nvidia = shards_for("nvidia-tuned")
    assert len(nvidia) == len(IMAGES) + 1, "expected one shard per image plus pinned-image"
    assert nvidia[-1]["shard"] == "pinned-image"
    assert {s["base_image"] for s in nvidia[:-1]} == set(IMAGES)

    for package in ("bind-mount", "shellscript", "tuning"):
        assert shards_for(package) == [
            {"package": package, "shard": "all", "args": "", "base_image": ""}
        ], f"{package} should not be sharded"
