#!/bin/bash

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

# Verify running kernel matches expected from defaults/env overrides.
# Only runs when NVIDIA_SETUP_INSTALL_KERNEL=true (same env var that triggers kernel install).
set -e

if [ "${NVIDIA_SETUP_INSTALL_KERNEL:-false}" != "true" ]; then
  exit 0
fi

# shellcheck source=../load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

if [ -f "${SKYHOOK_DIR}/skyhook_dir/utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "$(dirname "$0")/../utilities.sh" ]; then
  . "$(dirname "$0")/../utilities.sh"
else
  echo "ERROR: utilities.sh not found" >&2
  exit 1
fi

expected="$(resolve_full_kernel "${KERNEL}")"
current=$(uname -r)

if [ "${current}" != "${expected}" ]; then
  echo "Error: running kernel ${current} does not match expected ${expected} (from defaults/env)." >&2
  exit 1
fi

exit 0
