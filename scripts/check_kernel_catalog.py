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

"""Check that every kernel in the nvidia-setup catalog is installable on both arches.

Renovate bumps a catalog line from the amd64 index only. On arm64 nvidia-setup
installs the -64k flavor of the same ABI from ports.ubuntu.com, which can lag
behind. This check fails a catalog change unless the packages install_kernel.sh
installs (linux-image, linux-headers and linux-modules) are published for every
line on both amd64 and arm64.

Stdlib only, so CI can run it with the runner's python3.

Usage: check_kernel_catalog.py [path/to/kernels.conf]
"""

import gzip
import http.client
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Set, Tuple

DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "nvidia-setup" / "skyhook_dir" / "kernels.conf"

# arch -> (mirror, package-name suffix that resolve_full_kernel adds on that arch)
ARCHES: Dict[str, Tuple[str, str]] = {
    "amd64": ("https://archive.ubuntu.com/ubuntu", ""),
    "arm64": ("https://ports.ubuntu.com/ubuntu-ports", "-64k"),
}
# A kernel ABI can sit in any of these pockets; apt on a node sees all three.
POCKETS = ("", "-updates", "-security")
COMPONENT = "main"
# What install_kernel.sh always installs. linux-modules-extra is optional there.
PACKAGE_PREFIXES = ("linux-image-", "linux-headers-", "linux-modules-")


@dataclass(frozen=True)
class CatalogEntry:
    flavor: str
    track: str
    release: str
    abi: str
    line: int


def parse_catalog(text: str) -> List[CatalogEntry]:
    """Catalog lines the same way load_defaults.sh reads them: skip comments, need 4 fields."""
    entries = []
    for number, raw in enumerate(text.splitlines(), start=1):
        fields = raw.split()
        if not fields or fields[0].startswith("#") or len(fields) < 4:
            continue
        flavor, track, release, abi = fields[:4]
        entries.append(CatalogEntry(flavor, track, release, abi, number))
    return entries


def package_names(index: str) -> Set[str]:
    """Package names in a Debian Packages index."""
    return {line[len("Package:"):].strip() for line in index.splitlines() if line.startswith("Package:")}


def required_packages(abi: str, arch: str) -> List[str]:
    suffix = ARCHES[arch][1]
    full = abi if abi.endswith(suffix) else abi + suffix
    return [prefix + full for prefix in PACKAGE_PREFIXES]


def index_url(arch: str, release: str, pocket: str) -> str:
    mirror = ARCHES[arch][0]
    return f"{mirror}/dists/{release}{pocket}/{COMPONENT}/binary-{arch}/Packages.gz"


class FetchError(Exception):
    pass


def fetch_index(url: str, attempts: int = 3) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "nodewright-packages-kernel-catalog-check"})
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return gzip.decompress(response.read()).decode("utf-8", errors="replace")
        except (OSError, http.client.HTTPException, EOFError) as error:
            # A dropped connection mid-download is common on the Ubuntu mirrors; retry it.
            if attempt == attempts:
                raise FetchError(f"{url}: {error}") from error
            time.sleep(5 * attempt)
    raise AssertionError("unreachable")


def check(entries: Iterable[CatalogEntry], fetch: Optional[Callable[[str], str]] = None) -> List[str]:
    """Return one problem string per missing package; empty means every line is installable."""
    fetch = fetch or fetch_index
    published: Dict[Tuple[str, str], Set[str]] = {}
    problems = []
    for entry in entries:
        for arch in ARCHES:
            key = (arch, entry.release)
            if key not in published:
                names: Set[str] = set()
                for pocket in POCKETS:
                    names |= package_names(fetch(index_url(arch, entry.release, pocket)))
                published[key] = names
            for package in required_packages(entry.abi, arch):
                if package not in published[key]:
                    problems.append(
                        f"line {entry.line} ({entry.flavor} {entry.track} {entry.release} {entry.abi}): "
                        f"{package} is not published for {arch} in {entry.release} {COMPONENT}"
                    )
    return problems


def main(argv: List[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_CATALOG
    entries = parse_catalog(path.read_text())
    if not entries:
        print(f"ERROR: no kernels in {path}", file=sys.stderr)
        return 1
    try:
        problems = check(entries)
    except FetchError as error:
        print(f"ERROR: could not read a package index: {error}", file=sys.stderr)
        return 2
    for entry in entries:
        print(f"{entry.flavor} {entry.track} {entry.release} {entry.abi}")
    if problems:
        print("\nNot installable on every arch:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"\nAll {len(entries)} catalog kernel(s) are published for {', '.join(ARCHES)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
