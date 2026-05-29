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

# Alias the upstream-style kernel source tree to Ubuntu's linux-headers tree so
# consumers (gpu-operator nvidia-driver-daemonset, NVIDIA DRA driver) that read
# /usr/src/linux-$(uname -r)/.config find it.
#
# On Ubuntu the file only exists at /usr/src/linux-headers-$(uname -r)/.config.
# See https://github.com/NVIDIA/aicr/issues/1093.

set -euo pipefail

KERNEL_RELEASE="$(uname -r)"
HEADERS_NAME="linux-headers-${KERNEL_RELEASE}"
HEADERS_PATH="/usr/src/${HEADERS_NAME}"
LINK_PATH="/usr/src/linux-${KERNEL_RELEASE}"

if [ ! -d "${HEADERS_PATH}" ]; then
  echo "ERROR: ${HEADERS_PATH} does not exist; install linux-headers-${KERNEL_RELEASE} first" >&2
  exit 1
fi

# Already correct: a symlink whose target matches HEADERS_NAME. Idempotent re-run.
if [ -L "${LINK_PATH}" ] && [ "$(readlink "${LINK_PATH}")" = "${HEADERS_NAME}" ]; then
  echo "OK: ${LINK_PATH} already points to ${HEADERS_NAME}"
  exit 0
fi

# Refuse to clobber a real directory at LINK_PATH — that would be a real kernel
# source tree (Debian linux-source or hand-built) and removing it is not safe.
if [ -e "${LINK_PATH}" ] && [ ! -L "${LINK_PATH}" ]; then
  echo "ERROR: ${LINK_PATH} exists and is not a symlink; refusing to replace it" >&2
  exit 1
fi

# Stale or wrong symlink — replace it with the correct one.
ln -sfn "${HEADERS_NAME}" "${LINK_PATH}"
echo "linked ${LINK_PATH} -> ${HEADERS_NAME}"
