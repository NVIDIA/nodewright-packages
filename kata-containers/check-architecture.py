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


"""Reject foreign-architecture executables, even when binfmt can execute them."""

import argparse
from pathlib import Path
import struct


MACHINES = {"amd64": 62, "arm64": 183}


def check_binary(path, architecture):
    with path.open("rb") as binary:
        header = binary.read(20)
    if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01":
        raise ValueError(f"{path}: expected a 64-bit little-endian ELF executable")
    machine = struct.unpack_from("<H", header, 18)[0]
    if machine != MACHINES[architecture]:
        raise ValueError(f"{path}: ELF machine {machine} does not match {architecture}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("architecture", choices=MACHINES)
    parser.add_argument("binaries", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        for path in args.binaries:
            check_binary(path, args.architecture)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
