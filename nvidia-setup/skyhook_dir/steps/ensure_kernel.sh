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

# ensure_kernel.sh: install exact kernel (if NVIDIA_SETUP_INSTALL_KERNEL=true) or
# verify current kernel meets requirement (see NVIDIA_SETUP_KERNEL_ALLOW_NEWER).
set -e
#
# NVIDIA_SETUP_KERNEL_ALLOW_NEWER (default: false). When false, the running kernel
# must match the required upstream version exactly. When true, the running kernel
# may be newer (current >= required).

STEPS_DIR="${SKYHOOK_DIR}/skyhook_dir/steps"

if [ -f "${SKYHOOK_DIR}/skyhook_dir/utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "$(dirname "$0")/../utilities.sh" ]; then
  . "$(dirname "$0")/../utilities.sh"
else
  echo "ERROR: utilities.sh not found" >&2
  exit 1
fi

install_kernel() {
  "${STEPS_DIR}/install_kernel.sh" "${KERNEL}"
}

# Returns 0 if current >= required (by upstream version).
# Compares only the upstream part (before first '-') so local suffixes like
# -1007-aws vs -1018-aws do not reverse the order (sort -V on full uname -r
# can treat 6.17.0-1007 as "smaller" than 6.14.0-1018 because 1007 < 1018).
check_kernel_at_least() {
  local required="$1"
  local current
  current=$(uname -r)
  local required_upstream="${required%%-*}"
  local current_upstream="${current%%-*}"
  local first
  first=$(printf '%s\n' "${required_upstream}" "${current_upstream}" | sort -V | head -n1)
  if [ "${first}" = "${required_upstream}" ]; then
    return 0
  fi
  return 1
}

# Returns 0 if current upstream version equals required upstream version (exact match).
check_kernel_exact() {
  local required="$1"
  local current
  current=$(uname -r)
  local required_upstream="${required%%-*}"
  local current_upstream="${current%%-*}"
  [ "${current_upstream}" = "${required_upstream}" ]
}

# When TEST_CHECK_KERNEL_AT_LEAST is set, skip normal execution so tests can source this file and call check_kernel_at_least.
if [ -z "${TEST_CHECK_KERNEL_AT_LEAST:-}" ]; then
  if [ -z "${KERNEL:-}" ]; then
    echo "No KERNEL configured for combination ${COMBINATION}; skipping kernel handling"
    exit 0
  fi

  if [ "${NVIDIA_SETUP_INSTALL_KERNEL:-false}" = "true" ]; then
    install_kernel
    exit 0
  fi

  # Check current kernel meets requirement (exact or at-least depending on env)
  required_full="$(resolve_full_kernel "${KERNEL}")"
  if [ "${NVIDIA_SETUP_KERNEL_ALLOW_NEWER:-false}" = "true" ]; then
    if ! check_kernel_at_least "${required_full}"; then
      echo "Error: current kernel $(uname -r) is not >= required ${required_full}. Set NVIDIA_SETUP_INSTALL_KERNEL=true to install the exact kernel, or boot with a compatible kernel." >&2
      exit 1
    fi
  else
    if ! check_kernel_exact "${required_full}"; then
      echo "Error: current kernel $(uname -r) does not match required ${required_full} (exact match required). Set NVIDIA_SETUP_KERNEL_ALLOW_NEWER=true to allow a newer kernel, or NVIDIA_SETUP_INSTALL_KERNEL=true to install the exact kernel." >&2
      exit 1
    fi
  fi
fi
