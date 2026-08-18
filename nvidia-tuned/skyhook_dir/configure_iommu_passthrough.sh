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

# Disables IOMMU passthrough on kernels that need it to run ACS + DMA-BUF.
#
# OCI ships iommu.passthrough=1, so devices sit behind an identity domain. arm-smmu-v3
# before 6.11 cannot attach a PASID to an identity domain, so nvidia_uvm's ATS/SVA bind
# fails with -E2BIG and no CUDA context can be created at all -- cudaMalloc reports the
# GPUs as busy on an idle node. Setting iommu.passthrough=0 restores translating domains,
# and with them CUDA, GPUDirect RDMA and the DMA-BUF path the ACS correction sets up.
#
# Upstream: 6.10 made CD tables allocate-on-demand, 6.11 added S1DSS_BYPASS (PASID on an
# identity STE). 6.11 is the threshold.
#
# Scoped to affected kernels rather than applied everywhere because translating domains
# cost DMA performance, which is why the platform sets passthrough in the first place. On
# a kernel with the fix there is nothing to buy with that cost, so applying it there would
# be a straight regression on nodes that are already healthy.
#
# Gated on ${SKYHOOK_DIR}/profiles/service/${service}/iommu-passthrough-${accelerator}.enabled,
# so pairs without the marker are a no-op. CONFIGURE_IOMMU_PASSTHROUGH picks the policy:
# auto (default, apply below IOMMU_PASSTHROUGH_MIN_KERNEL), true (always), false (never).
# auto reads uname and vendor kernels backport, so it can guess wrong either way; the
# explicit values are the escape hatch.
#
# Lands on the kernel command line, so it needs `interrupt: {type: reboot}`.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

# Overridable so tests can point at a stub.
IOMMU_GRUB_DROPIN="${IOMMU_GRUB_DROPIN:-/etc/default/grub.d/99-iommu-passthrough.cfg}"
# First kernel with arm-smmu-v3 S1DSS_BYPASS. Overridable so tests can pin the
# threshold; not an operator knob -- use CONFIGURE_IOMMU_PASSTHROUGH instead.
IOMMU_PASSTHROUGH_MIN_KERNEL="${IOMMU_PASSTHROUGH_MIN_KERNEL:-6.11}"

# 99- sorts after every numbered producer, so this assignment is evaluated last.
# iommu.passthrough is an early_param and do_early_param() runs the handler on each
# occurrence in order, so the last value wins. Appending rather than rewriting keeps this
# correct whether or not the platform ships its own drop-in.
DROPIN_CONTENT="$(cat <<'EOF'
# Managed by the nvidia-tuned Skyhook package. Do not edit.
#
# arm-smmu-v3 before 6.11 cannot attach a PASID to an identity domain, which breaks GPU
# ATS/SVA under iommu.passthrough=1. Sorts last so this value is the one that applies.
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX iommu.passthrough=0"
EOF
)"

# Returns 0 when the configured service/accelerator opts in.
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

# Echoes always | never | auto. Unrecognised values are auto.
iommu_policy() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_IOMMU_PASSTHROUGH:-auto}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) echo "never" ;;
        true | 1 | yes | on) echo "always" ;;
        *) echo "auto" ;;
    esac
}

# Returns 0 when uname -r is older than IOMMU_PASSTHROUGH_MIN_KERNEL (major.minor only).
# An unparseable version is treated as new enough: applying a boot-affecting change to an
# unknown platform is the worse failure.
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
        echo "WARNING: cannot parse kernel version '${rel}'; treating as new enough"
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
        exit 1
    fi
}

# Drop a drop-in this package previously wrote. Without this, `false` cannot restore
# passthrough and a kernel upgraded past the threshold keeps the workaround pinned on,
# because the stale file still contributes iommu.passthrough=0 at the next boot.
remove_dropin() {
    [[ -f "${IOMMU_GRUB_DROPIN}" ]] || return 0

    rm -f "${IOMMU_GRUB_DROPIN}"
    regenerate_grub
    echo "Removed ${IOMMU_GRUB_DROPIN}; a reboot is required to restore IOMMU passthrough"
}

main() {
    local policy
    policy="$(iommu_policy)"

    if ! iommu_enabled; then
        echo "IOMMU passthrough workaround not enabled for this service/accelerator; nothing to do"
        return 0
    fi

    if [[ "${policy}" == "never" ]]; then
        echo "IOMMU passthrough workaround switched off via CONFIGURE_IOMMU_PASSTHROUGH"
        remove_dropin
        return 0
    fi

    if [[ "${policy}" == "auto" ]] && ! kernel_predates_fix; then
        echo "Kernel $(uname -r) is >= ${IOMMU_PASSTHROUGH_MIN_KERNEL}; passthrough is fine here"
        remove_dropin
        return 0
    fi

    # Compare content rather than just existence, so a drop-in left by an older version of
    # this package is corrected instead of silently kept.
    if [[ -f "${IOMMU_GRUB_DROPIN}" ]] \
        && [[ "$(cat "${IOMMU_GRUB_DROPIN}")" == "${DROPIN_CONTENT}" ]]; then
        echo "IOMMU passthrough drop-in already current at ${IOMMU_GRUB_DROPIN}; nothing to do"
        return 0
    fi

    echo "Kernel $(uname -r) predates ${IOMMU_PASSTHROUGH_MIN_KERNEL}; disabling IOMMU passthrough"
    mkdir -p "$(dirname "${IOMMU_GRUB_DROPIN}")"
    printf '%s\n' "${DROPIN_CONTENT}" > "${IOMMU_GRUB_DROPIN}"
    regenerate_grub
    echo "Wrote ${IOMMU_GRUB_DROPIN}; a reboot is required for it to take effect"
}

main "$@"
