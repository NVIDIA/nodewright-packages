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
  full_kernel_ver="$(resolve_full_kernel "${KERNEL_VERSION}")"
  local kernel_packages
  mapfile -t kernel_packages < <(target_kernel_packages "${full_kernel_ver}")

  # Booted on the exact target (flavor included) with every package in place
  # leaves apt nothing to do, and running it anyway makes this step depend on the
  # network, the archive and an undamaged dpkg database. The GRUB steps below
  # still run: pinning the boot default is what keeps a later kernel install
  # from taking over the next boot.
  if [ "${CURRENT_KERNEL_VERSION}" = "${full_kernel_ver}" ] \
    && dpkg_packages_installed "${kernel_packages[@]}"; then
    echo "Kernel ${full_kernel_ver} is running and installed; skipping apt"
  else
    apt_with_dpkg_heal apt-get update
    # Installing the kernel makes dkms build every efa module it has for it, and
    # a build failure leaves the kernel packages half-configured, which every
    # later apt call then trips over (aicr#2870: efa 3.0.0 against 7.0). So
    # bring EFA to the configured driver first, while the running kernel can
    # still build it. A node with no efa module has nothing to rebuild; the full
    # setup installs EFA after the reboot.
    if [ -n "${EFA:-}" ] && efa_dkms_registered && ! efa_driver_current "${EFA_DRIVER}"; then
      echo "Upgrading EFA to installer ${EFA} before installing kernel ${full_kernel_ver}..."
      "$(dirname "$0")/install-efa-driver.sh" "${EFA}" "${EFA_DRIVER}"
    fi
    # The lists are current now, so ask again whether the target has a
    # linux-modules-extra package.
    mapfile -t kernel_packages < <(target_kernel_packages "${full_kernel_ver}")
    echo "Installing kernel ${full_kernel_ver}..."
    apt_with_dpkg_heal apt-get install -y "${kernel_packages[@]}"
  fi

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
  local pkg
  for pkg in "${kernel_packages[@]}"; do
    printf 'Package: %s\nPin: version %s*\nPin-Priority: 1001\n\n' "${pkg}" "${KERNEL_VERSION}"
  done > pin-kernel

    # Move the pin file to the preferences.d directory
    mv pin-kernel /etc/apt/preferences.d/pin-kernel
    chown root:root /etc/apt/preferences.d/pin-kernel

    if [[ $CURRENT_KERNEL_VERSION != "${full_kernel_ver}" ]]; then
      # Hold the Kernel packages
      apt-mark hold "${kernel_packages[@]}"
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
