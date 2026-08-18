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

# Verifies IOMMU translation is live after the reboot interrupt.
#
# GATES: if the workaround was requested and did not take effect, the node cannot run
# CUDA at all, so this fails rather than letting it come up broken.
# CONFIGURE_IOMMU_PASSTHROUGH=false skips both the change and this check.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"
IOMMU_GROUPS_DIR="${IOMMU_GROUPS_DIR:-/sys/kernel/iommu_groups}"
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

# The effective iommu.passthrough value, or empty if unset.
#
# The token legitimately appears twice: the platform sets 1 and our drop-in appends 0.
# The last occurrence is the one the kernel acted on, so grepping for =0 anywhere would
# pass even when something later set it back to 1 -- the failure this check exists for.
effective_passthrough() {
    tr ' ' '\n' < "${PROC_CMDLINE}" \
        | grep '^iommu\.passthrough=' \
        | tail -1 \
        | cut -d= -f2
}

# True when at least one IOMMU group uses a translating domain.
#
# sysfs rather than the dmesg "Default domain type:" line, which can wrap out of the ring
# buffer. Only "at least one" is required: a driver may legitimately request an identity
# domain for its own device.
translation_active() {
    local t
    for t in "${IOMMU_GROUPS_DIR}"/*/type; do
        [[ -r "${t}" ]] || continue
        case "$(cat "${t}" 2>/dev/null)" in
            DMA | DMA-FQ) return 0 ;;
        esac
    done
    return 1
}

main() {
    local policy effective

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
        echo "Kernel $(uname -r) is >= ${IOMMU_PASSTHROUGH_MIN_KERNEL}; passthrough is fine on this kernel, nothing to verify"
        return 0
    fi

    effective="$(effective_passthrough)"

    if [[ "${effective}" == "1" ]]; then
        fail_not_applied \
            "The booted kernel command line still resolves iommu.passthrough to 1. The last occurrence wins, so a file sorting after 99-iommu-passthrough.cfg in /etc/default/grub.d/ is overriding it, or the drop-in never reached grub.cfg. Check which entry GRUB_DEFAULT boots."
    fi

    if ! translation_active; then
        fail_not_applied \
            "No IOMMU group under ${IOMMU_GROUPS_DIR} is using a translating (DMA or DMA-FQ) domain, so the SMMU is still in bypass. 'dmesg | grep \"Default domain type\"' shows what the kernel resolved at boot."
    fi

    echo "Verified IOMMU translation is active after reboot (iommu.passthrough=${effective:-unset})"
}

# The only place an operator will look, so name the cause, the cost and the switch.
fail_not_applied() {
    cat <<EOF
ERROR: The IOMMU passthrough workaround was requested but did not take effect on this node.

  ${1}

  Impact: on a kernel older than ${IOMMU_PASSTHROUGH_MIN_KERNEL}, arm-smmu-v3 cannot attach a PASID to an
  identity domain, so nvidia_uvm's ATS/SVA bind fails with -E2BIG and NO CUDA context
  can be created. cudaMalloc reports "CUDA-capable device(s) is/are busy or unavailable"
  even with no processes on the GPUs. DCGM, the GPU operator validators and every GPU
  workload fail together. Look for arm_smmu_write_ctx_desc in dmesg to confirm.

  If this node should keep IOMMU passthrough (for example its kernel carries a backported
  fix that the version check cannot see), set CONFIGURE_IOMMU_PASSTHROUGH=false in the
  package env on the custom resource. That skips the change and this check.
EOF
    exit 1
}

main "$@"
