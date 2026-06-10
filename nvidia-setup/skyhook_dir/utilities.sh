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

# resolve_full_kernel for nvidia-setup (skyhook): no get_var; use KERNEL and architecture.
# The conf (defaults/<service>-<accelerator>.conf) already specifies the exact kernel
# flavor (e.g. 6.17.0-1017-aws), so the only thing left to resolve is the
# architecture-specific page-size variant: arm64/aarch64 nodes (e.g. GB200/Grace) use
# the -64k kernel, x86_64 nodes use the flavor as-is.
# Usage: resolve_full_kernel <base_kernel_version>
# Returns: <conf_kernel>[-64k]
resolve_full_kernel() {
  local base_version="$1"
  if [ -z "${base_version}" ]; then
    base_version="${KERNEL:-}"
  fi
  if [ -z "${base_version}" ]; then
    echo "ERROR: kernel version not set" >&2
    return 1
  fi
  # arm64 uses the 64k page-size kernel; append -64k unless the conf already has it.
  local arch
  arch=$(uname -m)
  case "${arch}" in
    arm64 | aarch64)
      case "${base_version}" in
        *-64k) echo "${base_version}" ;;
        *)     echo "${base_version}-64k" ;;
      esac
      ;;
    *)
      echo "${base_version}"
      ;;
  esac
}
