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

"""Unit tests for scripts/check_kernel_catalog.py against fixture Packages indexes (no network)."""

import importlib.util
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("check_kernel_catalog", REPO / "scripts" / "check_kernel_catalog.py")
ckc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ckc)

CATALOG = """\
# header comment
# renovate: datasource=deb depName=linux-image-aws-7.0 registryUrl=https://example.invalid
aws hwe noble 7.0.0-1018-aws
"""


def index(*names):
    return "".join(f"Package: {n}\nVersion: 1\n\n" for n in names)


def kernel_packages(abi):
    return [f"linux-image-{abi}", f"linux-headers-{abi}", f"linux-modules-{abi}"]


def fake_fetch(by_arch_pocket):
    """fetch() stand-in: maps (arch, pocket) to an index; unknown URLs are an empty index."""
    calls = []

    def fetch(url):
        calls.append(url)
        for (arch, pocket), text in by_arch_pocket.items():
            if url == ckc.index_url(arch, "noble", pocket):
                return text
        return ""

    fetch.calls = calls
    return fetch


def test_parse_catalog_skips_comments_and_short_lines():
    entries = ckc.parse_catalog(CATALOG + "aws hwe\n\n")
    assert entries == [ckc.CatalogEntry("aws", "hwe", "noble", "7.0.0-1018-aws", 3)]


def test_shipped_catalog_parses():
    entries = ckc.parse_catalog(ckc.DEFAULT_CATALOG.read_text())
    assert entries, "kernels.conf has no kernels"
    assert all(e.track in ("lts", "hwe") for e in entries)


def test_required_packages_add_64k_on_arm64_only():
    assert ckc.required_packages("7.0.0-1018-aws", "amd64") == kernel_packages("7.0.0-1018-aws")
    assert ckc.required_packages("7.0.0-1018-aws", "arm64") == kernel_packages("7.0.0-1018-aws-64k")
    # A catalog ABI that already carries -64k is not doubled, matching resolve_full_kernel.
    assert ckc.required_packages("7.0.0-1018-aws-64k", "arm64") == kernel_packages("7.0.0-1018-aws-64k")


def test_index_urls_use_ports_for_arm64():
    assert ckc.index_url("amd64", "noble", "-updates") == (
        "https://archive.ubuntu.com/ubuntu/dists/noble-updates/main/binary-amd64/Packages.gz"
    )
    assert ckc.index_url("arm64", "noble", "") == (
        "https://ports.ubuntu.com/ubuntu-ports/dists/noble/main/binary-arm64/Packages.gz"
    )


def test_passes_when_both_arches_publish_everything():
    fetch = fake_fetch({
        ("amd64", "-updates"): index(*kernel_packages("7.0.0-1018-aws")),
        ("arm64", "-updates"): index(*kernel_packages("7.0.0-1018-aws-64k")),
    })
    assert ckc.check(ckc.parse_catalog(CATALOG), fetch) == []


def test_fails_when_ports_lags_behind_on_64k():
    # amd64 has the new ABI (what Renovate saw); ports only has the old -64k one.
    fetch = fake_fetch({
        ("amd64", "-updates"): index(*kernel_packages("7.0.0-1018-aws")),
        ("arm64", "-updates"): index(*kernel_packages("7.0.0-1014-aws-64k"), *kernel_packages("7.0.0-1018-aws")),
    })
    problems = ckc.check(ckc.parse_catalog(CATALOG), fetch)
    assert len(problems) == 3
    assert all("arm64" in p and "-64k" in p for p in problems)
    assert "line 3 (aws hwe noble 7.0.0-1018-aws)" in problems[0]


def test_fails_on_a_single_missing_package():
    fetch = fake_fetch({
        ("amd64", "-updates"): index("linux-image-7.0.0-1018-aws", "linux-headers-7.0.0-1018-aws"),
        ("arm64", "-updates"): index(*kernel_packages("7.0.0-1018-aws-64k")),
    })
    problems = ckc.check(ckc.parse_catalog(CATALOG), fetch)
    assert problems == [
        "line 3 (aws hwe noble 7.0.0-1018-aws): linux-modules-7.0.0-1018-aws is not published for amd64 in noble main"
    ]


@pytest.mark.parametrize("pocket", ["", "-updates", "-security"])
def test_any_pocket_counts(pocket):
    fetch = fake_fetch({
        ("amd64", pocket): index(*kernel_packages("7.0.0-1018-aws")),
        ("arm64", pocket): index(*kernel_packages("7.0.0-1018-aws-64k")),
    })
    assert ckc.check(ckc.parse_catalog(CATALOG), fetch) == []


def test_indexes_fetched_once_per_arch_and_release():
    two_lines = CATALOG + "aws lts noble 6.8.0-1040-aws\n"
    fetch = fake_fetch({})
    ckc.check(ckc.parse_catalog(two_lines), fetch)
    assert len(fetch.calls) == len(ckc.ARCHES) * len(ckc.POCKETS)


def test_main_fails_on_empty_catalog(tmp_path, capsys):
    empty = tmp_path / "kernels.conf"
    empty.write_text("# nothing here\n")
    assert ckc.main(["check_kernel_catalog.py", str(empty)]) == 1
    assert "no kernels" in capsys.readouterr().err


def test_main_reports_an_unreadable_index(tmp_path, monkeypatch, capsys):
    catalog = tmp_path / "kernels.conf"
    catalog.write_text(CATALOG)

    def broken(url):
        raise ckc.FetchError(f"{url}: connection reset")

    monkeypatch.setattr(ckc, "fetch_index", broken)
    assert ckc.main(["check_kernel_catalog.py", str(catalog)]) == 2
    assert "could not read a package index" in capsys.readouterr().err
