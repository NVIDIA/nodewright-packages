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

# Install setup-local-disks to /usr/local/bin and run it directly.
# Usage: run with optional first arg: raid0 | mount | none (default: raid0 for EKS)
set -e
DISK_MODE="${1:-raid0}"

# Load helpers (nvidia-setup skyhook_dir layout)
if [ -f "${SKYHOOK_DIR:-}/skyhook_dir/utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "$(dirname "$0")/../utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "$(dirname "$0")/../utilities.sh"
else
  echo "ERROR: utilities.sh not found" >&2
  exit 1
fi

# setup-local-disks uses mdadm (RAID) and mkfs.xfs; ensure they are installed
if ! command -v mdadm >/dev/null 2>&1 || ! command -v mkfs.xfs >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt_with_dpkg_heal apt-get update -qq
  apt_with_dpkg_heal apt-get install -y -qq mdadm xfsprogs
fi

cp "${SKYHOOK_DIR}/skyhook_dir/setup-local-disks.sh" /usr/local/bin/setup-local-disks
chmod 755 /usr/local/bin/setup-local-disks
/usr/local/bin/setup-local-disks "${DISK_MODE}"
