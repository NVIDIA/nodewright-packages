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


set -eo pipefail

KERNEL_VERSION="${1:?KERNEL_VERSION required}"

export DEBIAN_FRONTEND=noninteractive

# Load helpers (nvidia-setup skyhook_dir layout)
if [ -f "${SKYHOOK_DIR}/skyhook_dir/utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "$(dirname "$0")/../utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "$(dirname "$0")/../utilities.sh"
else
  echo "ERROR: utilities.sh not found" >&2
  exit 1
fi

CURRENT_KERNEL_VERSION=$(uname -r)

downgrade_kernel() {
  # Deterministic selection: construct the exact kernel flavor to install
  apt update
  full_kernel_ver="$(resolve_full_kernel "${KERNEL_VERSION}")"

  # Install older kernel headers
  echo "Installing kernel ${full_kernel_ver}..."
  apt-get install -y \
    linux-image-$full_kernel_ver \
    linux-headers-$full_kernel_ver \
    linux-modules-$full_kernel_ver \
    linux-modules-extra-$full_kernel_ver
    
  # Update grub to make sure the new kernel is available 
  update-grub

  # List all installed kernels
  dpkg --list | grep linux-image

  # Set the default kernel version in /etc/default/grub
  sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' /etc/default/grub
  grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux ${full_kernel_ver}"
  update-grub


  if [ "${NVIDIA_PIN_KERNEL:-false}" = "true" ]; then
  # Pin the kernel packages to prevent them from being updated
  cat << EOF > pin-kernel
Package: linux-image-$full_kernel_ver
Pin: version $KERNEL_VERSION*
Pin-Priority: 1001

Package: linux-headers-$full_kernel_ver
Pin: version $KERNEL_VERSION*
Pin-Priority: 1001

Package: linux-modules-$full_kernel_ver
Pin: version $KERNEL_VERSION*
Pin-Priority: 1001

Package: linux-modules-extra-$full_kernel_ver
Pin: version $KERNEL_VERSION*
Pin-Priority: 1001
EOF

    # Move the pin file to the preferences.d directory
    mv pin-kernel /etc/apt/preferences.d/pin-kernel
    chown root:root /etc/apt/preferences.d/pin-kernel

    if [[ $CURRENT_KERNEL_VERSION != "${full_kernel_ver}" ]]; then
      # Hold the Kernel packages
      apt-mark hold \
        linux-image-$full_kernel_ver \
        linux-headers-$full_kernel_ver \
        linux-modules-$full_kernel_ver \
        linux-modules-extra-$full_kernel_ver
    fi

  fi

}

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  full_kernel_ver="$(resolve_full_kernel "${KERNEL_VERSION}")"
  echo "Skipping kernel install for test environment (target: ${full_kernel_ver})"
  exit 0
fi

# Do initial work
echo "Downgrading to target kernel version: ${KERNEL_VERSION}"
downgrade_kernel
echo "Done. Reboot to take effect."
