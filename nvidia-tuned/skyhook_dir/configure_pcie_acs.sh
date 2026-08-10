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

# Corrects the PCIe ACS settings on the RoCE NIC root ports so peer-to-peer DMA works.
#
# Why this exists: GB300 nodes ship with ACS enabled on the NIC root ports, which blocks
# peer-to-peer DMA between the GPUs and the RoCE NICs. `rdma_topo check` fails on every
# stock node, mlx5dv_reg_dmabuf_mr returns ENOTSUPP, and NCCL falls back to a slower
# path. Correcting ACS raised measured all_reduce peak busbw from 360 GB/s to 426 GB/s
# on a two-node, eight-GPU RoCE run, and made DMA-BUF work, which removes the need for
# nvidia_peermem and NCCL_DMABUF_ENABLE=0 wherever the correction takes effect.
#
# The values are per-topology: `rdma_topo write-grub-acs` generates a
# `pci=config_acs=...` line containing the local PCI addresses into
# /etc/default/grub.d/config-acs.cfg. That output is NOT portable across shapes, so it
# is generated on the node rather than baked into this image. The tool itself is
# shape-agnostic and idempotent.
#
# This step self-gates on a bundled marker file at:
#   ${SKYHOOK_DIR}/profiles/service/${service}/pcie-acs-${accelerator}.enabled
# so every service/accelerator combination without the marker is a no-op. Today only
# service=oci, accelerator=gb300 opts in.
#
# On top of that, operators can turn the step off per deployment with the
# CONFIGURE_PCIE_ACS env var. It defaults to on. The escape hatch matters because
# `pci=config_acs=` is not honoured by every kernel: on a kernel that ignores it the
# generated drop-in has no effect and nvidia_peermem stays required. Rather than probe
# kernel versions, the step is simply switchable.
#
# The change lands on the kernel command line, so it requires a reboot. Declare
# `interrupt: {type: reboot}` on the custom resource; post_interrupt_pcie_acs_check.sh
# then verifies the corrected values are live, and fails if they are not.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

# Overridable so tests can point at a stub.
RDMA_TOPO_BIN="${RDMA_TOPO_BIN:-rdma_topo}"

# Returns 0 unless the operator switched the step off via CONFIGURE_PCIE_ACS.
acs_requested() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_PCIE_ACS:-true}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Returns 0 when the configured service/accelerator opts in to the ACS fix.
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
    grep -q "ACS" <<< "${out}" || return 1
    ! grep -qE "^FAIL[[:space:]]+ACS" <<< "${out}"
}

# Regenerate the bootloader config. Mirrors the fallback chain in kdump's
# update_grub_config().
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

main() {
    if ! acs_enabled; then
        echo "PCIe ACS correction not enabled for this service/accelerator; nothing to do"
        return 0
    fi

    if ! acs_requested; then
        echo "PCIe ACS correction switched off via CONFIGURE_PCIE_ACS; nothing to do"
        return 0
    fi

    if ! command -v "${RDMA_TOPO_BIN}" >/dev/null 2>&1; then
        echo "ERROR: ${RDMA_TOPO_BIN} not found. It ships in the node image for this shape;"
        echo "       a node without it cannot have its ACS settings corrected."
        exit 1
    fi

    # `rdma_topo check` reads the live kernel state, so it keeps failing between the
    # grub write and the reboot. Re-running write-grub-acs in that window is harmless:
    # the tool regenerates the same drop-in from the same topology.
    if acs_values_correct; then
        echo "PCIe ACS values are already correct; nothing to do"
        return 0
    fi

    echo "PCIe ACS check failed; generating bootloader ACS configuration"
    "${RDMA_TOPO_BIN}" write-grub-acs
    regenerate_grub
    echo "Wrote PCIe ACS bootloader configuration; a reboot is required for it to take effect"
}

main "$@"
