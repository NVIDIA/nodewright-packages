#!/usr/bin/env bash

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

# Test harness: source load_defaults.sh the way the lifecycle scripts do, then print what it
# resolved so the tests can assert on it. load_defaults.sh exits non-zero on a bad track, so
# this script's exit code is the loader's.
set -euo pipefail

# FAKE_CODENAME pretends the node runs another Ubuntu release; "none" drops the codename.
if [[ -n "${FAKE_CODENAME:-}" ]]; then
  os_release="$(grep -v '^VERSION_CODENAME=' /etc/os-release)"
  rm -f /etc/os-release
  printf '%s\n' "${os_release}" > /etc/os-release
  [[ "${FAKE_CODENAME}" != "none" ]] && echo "VERSION_CODENAME=${FAKE_CODENAME}" >> /etc/os-release
fi

# shellcheck source=/dev/null
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

echo "KERNEL_FLAVOR=${KERNEL_FLAVOR}"
echo "KERNEL_TRACK=${KERNEL_TRACK}"
echo "KERNEL=${KERNEL}"
