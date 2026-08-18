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

# Verifies configure_iommu_passthrough.sh left a drop-in that will disable IOMMU
# passthrough on the next boot.
#
# Runs before the reboot, so live state still shows passthrough; passing only means the
# drop-in is in place. post_interrupt_iommu_passthrough_check.sh asserts it took effect.
# A non-zero exit is the signal, so no `set -e`.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

IOMMU_GRUB_DROPIN="${IOMMU_GRUB_DROPIN:-/etc/default/grub.d/99-iommu-passthrough.cfg}"
# First kernel with arm-smmu-v3 S1DSS_BYPASS. Overridable so tests can pin the
# threshold; not an operator knob -- use CONFIGURE_IOMMU_PASSTHROUGH instead.
IOMMU_PASSTHROUGH_MIN_KERNEL="${IOMMU_PASSTHROUGH_MIN_KERNEL:-6.11}"

# Mirrors iommu_enabled() in configure_iommu_passthrough.sh.
iommu_enabled() {
    local service accelerator

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 1
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 1

    [[ -f "${CONFIGMAP_DIR}/accelerator" ]] || return 1
    accelerator="$(xargs < "${CONFIGMAP_DIR}/accelerator")"
    [[ -n "${accelerator}" ]] || return 1

    [[ -f "${PROFILES_DIR}/service/${service}/iommu-passthrough-${accelerator}.enabled" ]]
}

# Mirrors iommu_policy() in configure_iommu_passthrough.sh.
iommu_policy() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_IOMMU_PASSTHROUGH:-auto}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) echo "never" ;;
        true | 1 | yes | on) echo "always" ;;
        *) echo "auto" ;;
    esac
}

# Mirrors kernel_predates_fix() in configure_iommu_passthrough.sh.
kernel_predates_fix() {
    local rel major minor want_major want_minor

    rel="$(uname -r)"
    major="${rel%%.*}"
    minor="${rel#*.}"
    minor="${minor%%.*}"

    want_major="${IOMMU_PASSTHROUGH_MIN_KERNEL%%.*}"
    want_minor="${IOMMU_PASSTHROUGH_MIN_KERNEL#*.}"
    want_minor="${want_minor%%.*}"

    if ! [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( major < want_major )); then
        return 0
    fi
    if (( major == want_major && minor < want_minor )); then
        return 0
    fi
    return 1
}

main() {
    local policy
    policy="$(iommu_policy)"

    if ! iommu_enabled; then
        echo "IOMMU passthrough workaround not enabled for this service/accelerator; nothing to verify"
        return 0
    fi

    if [[ "${policy}" == "never" ]]; then
        echo "IOMMU passthrough workaround switched off via CONFIGURE_IOMMU_PASSTHROUGH; nothing to verify"
        return 0
    fi

    if [[ "${policy}" == "auto" ]] && ! kernel_predates_fix; then
        echo "Kernel $(uname -r) is >= ${IOMMU_PASSTHROUGH_MIN_KERNEL}; no drop-in expected"
        return 0
    fi

    if [[ ! -f "${IOMMU_GRUB_DROPIN}" ]]; then
        echo "ERROR: IOMMU passthrough workaround was requested but no bootloader drop-in exists at ${IOMMU_GRUB_DROPIN}"
        exit 1
    fi

    # Match an active assignment, not a commented one, so a drop-in that contributes
    # nothing fails here rather than after the reboot. Comment-strip first; see the
    # equivalent note in configure_pcie_acs_check.sh for why one regex is not enough.
    if ! awk '{ sub(/#.*/, ""); if ($0 ~ /iommu\.passthrough=0/) found = 1 } END { exit !found }' \
        "${IOMMU_GRUB_DROPIN}"; then
        echo "ERROR: ${IOMMU_GRUB_DROPIN} does not contain an active iommu.passthrough=0 setting"
        exit 1
    fi

    echo "Verified IOMMU passthrough drop-in at ${IOMMU_GRUB_DROPIN}; pending reboot"
}

main "$@"
