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
EFA_VERSION="${1:?EFA version required}"
EFA_DRIVER_VERSION="${2:?EFA driver version required}"
export DEBIAN_FRONTEND=noninteractive

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

# A run that died partway, such as an OOM-killed DKMS build, leaves efa
# half-configured with its module already added to the DKMS tree. The
# installer's own apt calls then fail on `DKMS tree already contains` every
# time, and apt_with_dpkg_heal never sees it because nothing it wraps has failed
# yet. So repair first: dpkg_repair clears that entry and finishes the
# interrupted configure, which can complete the efa install outright.
if dpkg_needs_configure; then
  echo "dpkg has unfinished package configuration; repairing it before the EFA install..."
  dpkg_repair
fi

# Skip only when EFA is actually installed at the driver version this installer
# ships or newer (same criteria as install_efa_driver_check.sh). Anything short
# of that is a reason to install, not a reason to skip. Re-running over an older
# install upgrades it in place.
if efa_driver_current "${EFA_DRIVER_VERSION}"; then
  echo "EFA driver ${EFA_DRIVER_VERSION} or newer already installed, skipping."
  exit 0
fi

# Function to install EFA with retry logic
install_efa() {
  echo "Downloading EFA installer version ${EFA_VERSION}..."
  curl -sSfO "https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_VERSION}.tar.gz"
  tar -xf "aws-efa-installer-${EFA_VERSION}.tar.gz"
  cd aws-efa-installer

  ./efa_installer.sh -y
  echo "EFA installation completed successfully"
}

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  install_efa
else
  echo "Skipping efa install for test environment"
fi
