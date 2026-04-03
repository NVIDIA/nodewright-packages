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
export DEBIAN_FRONTEND=noninteractive

# Skip if EFA is already installed (same criteria as install_efa_driver_check.sh)
efa_already_installed() {
  [ -d /opt/amazon/efa ] && return 0
  ldconfig -p 2>/dev/null | grep -q libfabric && return 0
  dkms status 2>/dev/null | grep -q 'efa.*installed' && return 0
  return 1
}
if efa_already_installed; then
  echo "EFA already installed, skipping."
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
