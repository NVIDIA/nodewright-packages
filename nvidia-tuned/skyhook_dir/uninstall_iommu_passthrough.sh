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

# Removes the IOMMU passthrough drop-in written by configure_iommu_passthrough.sh.
#
# Runs unconditionally rather than self-gating on the service/accelerator assets:
# uninstall must also clean up after a custom resource whose configmaps have since
# changed, so it keys on what is on the host. Removing a drop-in that was never written
# is a no-op.
#
# Unlike the PCIe ACS drop-in, which corrects a hardware misconfiguration and is
# deliberately left in place, this one is purely a workaround for kernels that cannot
# attach a PASID to an identity domain. Removing it restores the platform's own
# passthrough setting, which is the correct as-if-never-installed state. Leaving it
# would keep forcing iommu.passthrough=0 on every future boot with no package owning it.
#
# Takes effect on the next boot, like the change it reverts.

set -euo pipefail

IOMMU_GRUB_DROPIN="${IOMMU_GRUB_DROPIN:-/etc/default/grub.d/99-iommu-passthrough.cfg}"

# Mirrors the fallback chain in kdump's update_grub_config().
regenerate_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        if [[ -d /boot/grub2 ]]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        else
            grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        fi
    else
        echo "ERROR: neither update-grub nor grub2-mkconfig is available"
        return 1
    fi
}

main() {
    if [[ ! -f "${IOMMU_GRUB_DROPIN}" ]]; then
        echo "${IOMMU_GRUB_DROPIN} is not present; nothing to remove"
        return 0
    fi

    # Back the drop-in up before removing it. If GRUB regeneration fails the generated
    # config still carries iommu.passthrough=0, and leaving the source file deleted would
    # make the next uninstall report success against a node that still boots with it.
    local backup
    backup="$(mktemp)"
    cp "${IOMMU_GRUB_DROPIN}" "${backup}"
    rm -f "${IOMMU_GRUB_DROPIN}"

    if ! regenerate_grub; then
        mv "${backup}" "${IOMMU_GRUB_DROPIN}"
        echo "ERROR: could not regenerate the bootloader config; restored ${IOMMU_GRUB_DROPIN}"
        return 1
    fi

    rm -f "${backup}"
    echo "Removed ${IOMMU_GRUB_DROPIN}; a reboot is required to restore IOMMU passthrough"
}

main "$@"
