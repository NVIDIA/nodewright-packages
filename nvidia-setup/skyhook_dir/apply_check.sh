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
STEPS_CHECK_DIR="${SKYHOOK_DIR}/skyhook_dir/steps_check"

# shellcheck source=load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

# Skip checks if only installing kernel as we need to reboot before any check would work
if [ "${NVIDIA_SETUP_INSTALL_KERNEL}" = "true" ]; then
  exit 0
fi

check_eks_h100() {
  "${STEPS_CHECK_DIR}/upgrade_check.sh"
  "${STEPS_CHECK_DIR}/install_efa_driver_check.sh"
  "${STEPS_CHECK_DIR}/install_ofi_check.sh"
  # "${STEPS_CHECK_DIR}/install_lustre_check.sh" "${KERNEL}"
  "${STEPS_CHECK_DIR}/configure_chrony_check.sh"
  "${STEPS_CHECK_DIR}/setup_local_disks_check.sh"
}

check_eks_gb200() {
  "${STEPS_CHECK_DIR}/upgrade_check.sh"
  "${STEPS_CHECK_DIR}/install_efa_driver_check.sh"
  "${STEPS_CHECK_DIR}/install_ofi_check.sh"
  # "${STEPS_CHECK_DIR}/install_lustre_check.sh" "${KERNEL}"
  "${STEPS_CHECK_DIR}/configure_chrony_check.sh"
  "${STEPS_CHECK_DIR}/setup_local_disks_check.sh"
}

case "${COMBINATION}" in
  eks-h100)  check_eks_h100 ;;
  eks-gb200) check_eks_gb200 ;;
  *)
    echo "Unsupported combination: ${COMBINATION}" >&2
    echo "Supported: $(find "${DEFAULTS_DIR}" -maxdepth 1 -name '*.conf' -exec basename {} .conf \; 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
    ;;
esac
