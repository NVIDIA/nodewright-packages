#!/usr/bin/env bash

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

# Verifies uninstall_iommu_passthrough.sh removed the IOMMU passthrough drop-in.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.
#
# Asserts the drop-in is gone rather than that passthrough is live: the change only takes
# effect at the next boot, so live state still shows whatever the running kernel booted
# with.

set -uo pipefail

IOMMU_GRUB_DROPIN="${IOMMU_GRUB_DROPIN:-/etc/default/grub.d/99-iommu-passthrough.cfg}"

main() {
    if [[ -e "${IOMMU_GRUB_DROPIN}" ]]; then
        echo "ERROR: ${IOMMU_GRUB_DROPIN} still present"
        exit 1
    fi

    echo "Verified the IOMMU passthrough drop-in is removed"
}

main "$@"
