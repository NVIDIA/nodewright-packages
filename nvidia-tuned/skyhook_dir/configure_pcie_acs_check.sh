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

# Verifies configure_pcie_acs.sh left the node in a state that will have correct ACS
# values after the next boot.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly. When the service/accelerator pair does not opt in,
# there is nothing to verify and this exits 0.
#
# This runs during config-check, before the reboot, so `rdma_topo check` is still
# expected to fail: it reads live kernel state and the fix lands on the kernel command
# line. Passing means either the node was already correct, or the bootloader drop-in is
# in place. post_interrupt_pcie_acs_check.sh asserts the values are actually live.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

ACS_GRUB_DROPIN="${ACS_GRUB_DROPIN:-/etc/default/grub.d/config-acs.cfg}"
RDMA_TOPO_BIN="${RDMA_TOPO_BIN:-rdma_topo}"

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
        echo "ERROR: ${RDMA_TOPO_BIN} not found"
        exit 1
    fi

    if "${RDMA_TOPO_BIN}" check; then
        echo "Verified PCIe ACS values are correct"
        return 0
    fi

    if [[ ! -f "${ACS_GRUB_DROPIN}" ]]; then
        echo "ERROR: PCIe ACS check failed and no bootloader drop-in at ${ACS_GRUB_DROPIN}"
        exit 1
    fi

    # Match an active assignment, not a commented example, so a drop-in that would
    # contribute nothing to the kernel command line fails here rather than surfacing as
    # a post-interrupt failure after the reboot.
    #
    # The optional group is what makes this correct, and it is easy to "simplify" wrong:
    #   ^[[:space:]]*[^#].*pci=config_acs=          matches "  # pci=config_acs=",
    #                                               because [^#] consumes a second space
    #   ^[[:space:]]*[^#[:space:]].*pci=config_acs= rejects a tab-indented active line,
    #                                               because .* then needs a second token
    # Making the leading group optional covers both: the token may start at the first
    # non-blank character, but that character must not be '#'.
    #
    # A `grep -v | grep -q` pipeline would also be correct but can return 141 under
    # pipefail when grep -q exits early and the upstream grep takes SIGPIPE.
    if ! grep -Eq '^[[:space:]]*([^#[:space:]].*)?pci=config_acs=' "${ACS_GRUB_DROPIN}"; then
        echo "ERROR: ${ACS_GRUB_DROPIN} does not contain an active pci=config_acs setting"
        exit 1
    fi

    echo "Verified PCIe ACS bootloader drop-in at ${ACS_GRUB_DROPIN}; pending reboot"
}

main "$@"
