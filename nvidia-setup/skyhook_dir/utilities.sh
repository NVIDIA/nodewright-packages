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
# Usage: resolve_full_kernel <base_kernel_version>
# Returns: <base_kernel_version>-aws[-64k] for EKS
resolve_full_kernel() {
  local base_version="$1"
  if [ -z "${base_version}" ]; then
    base_version="${KERNEL:-}"
  fi
  if [ -z "${base_version}" ]; then
    echo "ERROR: kernel version not set" >&2
    return 1
  fi
  # EKS on AWS: suffix is -aws
  local arch
  arch=$(uname -m)
  local suffix="-aws"
  if [ "${arch}" = "arm64" ] || [ "${arch}" = "aarch64" ]; then
    suffix="-aws-64k"
  fi
  # If base_version already contains -aws or similar, avoid duplicating
  case "${base_version}" in
    *-aws*) echo "${base_version}" ;;
    *)      echo "${base_version}${suffix}" ;;
  esac
}
