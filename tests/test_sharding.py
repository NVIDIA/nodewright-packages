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


def _node_ids(*args: str) -> set:
    """Return the exact set of test node IDs pytest selects for the given args.

    Compares identities rather than counts: equal totals can hide one test
    duplicated across shards and another omitted entirely, which would leave the
    suite unpartitioned while the arithmetic still balanced.

    Reads node IDs rather than the summary line, which with a deselection in play
    reads "37/122 tests collected" -- where the number that matters is the
    numerator, not the total.
    """
    result = subprocess.run(
        [sys.executable, "-m", "pytest", PACKAGE_DIR, "--collect-only", "-q", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    # pytest exits 5 for "no tests collected", a legitimate empty selection.
    if result.returncode == 5:
        return set()
    if result.returncode != 0:
        raise AssertionError(
            f"pytest --collect-only failed ({result.returncode}) for args {args!r}:\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return {line.strip() for line in result.stdout.splitlines() if "::" in line}


def _collected(*args: str) -> int:
    """Number of tests selected for the given args."""
    return len(_node_ids(*args))


@pytest.mark.timeout(600)
def test_shards_partition_the_suite_exactly():
    """Every test lands in exactly one shard: no omissions, no duplicates."""
    everything = _node_ids()
    shards = [
        _node_ids("--base-image", image, "--matrix-scope", "matrix") for image in IMAGES
    ]
    shards.append(_node_ids("--matrix-scope", "no-matrix"))

    covered = set().union(*shards)

    missing = everything - covered
    assert not missing, (
        f"{len(missing)} test(s) are in no shard and would silently never run in "
        f"CI, e.g. {sorted(missing)[:5]}"
    )

    extra = covered - everything
    assert not extra, f"shards select tests outside the suite: {sorted(extra)[:5]}"

    # Sum-of-sizes vs union size is what catches a test appearing in two shards.
    duplicated = sum(len(s) for s in shards) - len(covered)
    assert duplicated == 0, (
        f"{duplicated} test(s) appear in more than one shard and would run twice"
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
