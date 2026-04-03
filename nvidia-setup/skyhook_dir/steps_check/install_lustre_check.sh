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

set -e
KERNEL="${1:-$(uname -r)}"
# Lustre client modules package for this kernel
if dpkg -l 2>/dev/null | grep -q "lustre-client-modules-${KERNEL}"; then
  exit 0
fi
# Try without full kernel suffix (e.g. 5.15.0-1025-aws)
BASE="${KERNEL%-*}"
if dpkg -l 2>/dev/null | grep -q "lustre-client-modules"; then
  exit 0
fi
echo "Lustre client modules not found for kernel ${KERNEL}" >&2
exit 1
