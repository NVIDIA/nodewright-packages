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
STEPS_DIR="${SKYHOOK_DIR}/skyhook_dir/steps"

# shellcheck source=load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

NVIDIA_SETUP_INSTALL_KERNEL="${NVIDIA_SETUP_INSTALL_KERNEL:-false}"
export NVIDIA_SETUP_INSTALL_KERNEL SKYHOOK_DIR

# service=bcm's only job is to alias the kernel-headers tree (AICR #1093).
# Skip the kernel/EFA pipeline entirely.
if [ "${SERVICE}" = "bcm" ]; then
  "${STEPS_DIR}/setup_bcm_kernel_headers.sh"
  exit 0
fi

# If only installing kernel: run ensure_kernel (which installs and may reboot) and exit
if [ "${NVIDIA_SETUP_INSTALL_KERNEL}" = "true" ]; then
  "${STEPS_DIR}/ensure_kernel.sh"
  exit 0
fi

# Otherwise: ensure current kernel is >= required, then run full apply
"${STEPS_DIR}/ensure_kernel.sh"

run_eks_h100() {
  "${STEPS_DIR}/upgrade.sh"
  "${STEPS_DIR}/install-efa-driver.sh" "${EFA}"
  "${STEPS_DIR}/install_ofi.sh"
  # "${STEPS_DIR}/install-lustre.sh" "${KERNEL}" "${LUSTRE}"
  "${STEPS_DIR}/configure-chrony.sh"
  "${STEPS_DIR}/setup_local_disks.sh" raid0
}

run_eks_gb200() {
  "${STEPS_DIR}/upgrade.sh"
  "${STEPS_DIR}/install-efa-driver.sh" "${EFA}"
  "${STEPS_DIR}/install_ofi.sh"
  # "${STEPS_DIR}/install-lustre.sh" "${KERNEL}" "${LUSTRE}"
  "${STEPS_DIR}/configure-chrony.sh"
  "${STEPS_DIR}/setup_local_disks.sh" raid0
}

case "${COMBINATION}" in
  eks-h100)  run_eks_h100 ;;
  eks-gb200) run_eks_gb200 ;;
  *)
    echo "Unsupported combination: ${COMBINATION}" >&2
    echo "Supported: $(find "${DEFAULTS_DIR}" -maxdepth 1 -name '*.conf' -exec basename {} .conf \; 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
    ;;
esac
