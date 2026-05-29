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

# Verify the BCM/Ubuntu kernel-headers alias is in place for the running kernel.
# See setup_bcm_kernel_headers.sh and https://github.com/NVIDIA/aicr/issues/1093.

set -euo pipefail

KERNEL_RELEASE="$(uname -r)"
LINK_PATH="/usr/src/linux-${KERNEL_RELEASE}"
CONFIG_PATH="${LINK_PATH}/.config"

if [ ! -e "${LINK_PATH}" ]; then
  echo "ERROR: ${LINK_PATH} does not exist" >&2
  exit 1
fi

if [ ! -e "${CONFIG_PATH}" ]; then
  echo "ERROR: ${CONFIG_PATH} does not resolve" >&2
  exit 1
fi

echo "OK: ${CONFIG_PATH} resolves"
