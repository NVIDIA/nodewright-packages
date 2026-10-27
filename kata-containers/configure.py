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


"""Validate package metadata against the bundled Kata payload version."""

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
)


def kata_version(value):
    value = value.strip().removeprefix("v")
    if not VERSION.fullmatch(value):
        raise ValueError(f"Kata version must be an OCI-tag-compatible semantic version: {value!r}")
    return value


def package_config(template, payload_version, expected=None):
    version = kata_version(payload_version)
    if expected is not None and version != kata_version(expected):
        raise ValueError(f"requested Kata {expected} differs from payload Kata {version}")
    config = json.loads(template)
    if kata_version(config["package_version"]) != version:
        raise ValueError(f"package Kata {config['package_version']} differs from payload Kata {version}")
    config["package_version"] = version
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, default=ROOT / "config.json")
    parser.add_argument("--version-file", type=Path, required=True)
    parser.add_argument("--expected-version")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = package_config(args.template.read_text(), args.version_file.read_text(),
                                args.expected_version)
        args.output.write_text(json.dumps(config, indent=2) + "\n")
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
