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

# Verifies the corrected PCIe ACS values are live after the reboot interrupt.
#
# This check GATES: if the correction was requested and did not take effect, it exits
# non-zero and blocks post-interrupt validation, rather than letting the node quietly
# run degraded. The escape hatch is explicit rather than implicit: an operator who knows
# a node cannot support the correction sets CONFIGURE_PCIE_ACS=false, which skips both
# the correction and this check.
#
# Because a failure here stops the package, the message must be self-contained. It names
# the cause, what the node loses, and the switch to set. See fail_acs_not_applied().

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

RDMA_TOPO_BIN="${RDMA_TOPO_BIN:-rdma_topo}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"

# True when the PCIe ACS values are correct.
#
# Gates on the ACS lines rather than the tool's exit code. `rdma_topo check` also
# asserts GPU and DMA iommu_group topology, which requires the GPU driver to be loaded.
# That is not something this package controls, and on a new cluster it cannot be true
# yet: Skyhook taints the node, the GPU operator cannot install drivers until Skyhook
# completes, and Skyhook cannot complete while this check waits on the driver. Keying on
# the exit code deadlocks bringup.
#
# Requires at least one ACS line, so a tool that failed to run is not read as success.
acs_values_correct() {
    local out
    out="$("${RDMA_TOPO_BIN}" check 2>&1 || true)"
    # An ACS result record must be present. Merely mentioning ACS is not evidence: a
    # diagnostic such as "ACS query unavailable" would otherwise pass the presence test,
    # match no FAIL, and report unreadable state as correct.
    grep -qE "^(OK|FAIL)[[:space:]]+ACS([[:space:]]|$)" <<< "${out}" || return 1
    ! grep -qE "^FAIL[[:space:]]+ACS([[:space:]]|$)" <<< "${out}"
}

# Mirrors acs_requested() in configure_pcie_acs.sh.
acs_requested() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_PCIE_ACS:-true}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Mirrors acs_enabled() in configure_pcie_acs.sh.
acs_enabled() {
    local service accelerator

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 1
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 1

    [[ -f "${CONFIGMAP_DIR}/accelerator" ]] || return 1
    accelerator="$(xargs < "${CONFIGMAP_DIR}/accelerator")"
    [[ -n "${accelerator}" ]] || return 1

    [[ -f "${PROFILES_DIR}/service/${service}/pcie-acs-${accelerator}.enabled" ]]
}

main() {
    if ! acs_enabled; then
        echo "PCIe ACS correction not enabled for this service/accelerator; nothing to verify"
        return 0
    fi

    if ! acs_requested; then
        echo "PCIe ACS correction switched off via CONFIGURE_PCIE_ACS; nothing to verify"
        return 0
    fi

    if ! command -v "${RDMA_TOPO_BIN}" >/dev/null 2>&1; then
        fail_acs_not_applied "${RDMA_TOPO_BIN} is not installed on this node, so the ACS values cannot be read."
    fi

    if ! acs_values_correct; then
        if grep -q "config_acs" "${PROC_CMDLINE}"; then
            fail_acs_not_applied \
                "The booted kernel command line carries the config_acs argument but the ACS values are still wrong, so the kernel did not act on it. This is what a kernel without pci=config_acs= support looks like."
        else
            fail_acs_not_applied \
                "The booted kernel command line (${PROC_CMDLINE}) carries no config_acs argument, so the generated drop-in never reached the kernel. Check for a later-sorting file in /etc/default/grub.d/ that overwrites GRUB_CMDLINE_LINUX_DEFAULT, and check which entry GRUB_DEFAULT boots."
        fi
    fi

    echo "Verified PCIe ACS values are correct after reboot"
}

# Say clearly what is wrong, what it costs, and what to do, then fail. This is the only
# place an operator investigating the failure will look, so it must be self-contained.
fail_acs_not_applied() {
    cat <<EOF
ERROR: PCIe ACS correction was requested but did not take effect on this node.

  ${1}

  Impact: peer-to-peer DMA between the GPUs and the RoCE NICs stays blocked, so RDMA
  throughput is roughly 15% lower and DMA-BUF does not work. Workloads on this node
  still need nvidia_peermem loaded and NCCL_DMABUF_ENABLE=0 set.

  If this node cannot support the correction (for example its kernel does not honour
  pci=config_acs=), set CONFIGURE_PCIE_ACS=false in the package env on the custom
  resource. That skips the correction and this check, and the node proceeds without
  the ACS speedup.
EOF
    exit 1
}

main "$@"
