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

# Removes the RDMA VF readiness gate installed by install_rdma_vfs_ready.sh.
#
# This runs unconditionally rather than self-gating on the service/accelerator assets:
# uninstall must also clean up after a custom resource whose configmaps have since
# changed, so it keys on what is on the host, not on what the package currently bundles.
# Removing a unit that was never installed is a no-op.
#
# Leaving the unit behind would keep ordering kubelet after a gate that no package owns
# any more. The gate always exits 0, so the worst case is a delayed boot rather than a
# node that never joins, but it is still ours to remove.
#
# The PCIe ACS bootloader drop-in written by configure_pcie_acs.sh is deliberately NOT
# removed here. It corrects a hardware misconfiguration on the node rather than
# installing package state, reverting it would degrade RDMA performance, and it would
# not take effect until another reboot. Remove
# /etc/default/grub.d/config-acs.cfg by hand and re-run update-grub if you genuinely
# want the stock ACS values back.

set -euo pipefail

UNIT_NAME="rdma-vfs-ready.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
HELPER_DEST="/usr/local/sbin/wait-rdma-vfs.sh"

main() {
    if [[ ! -f "${UNIT_DEST}" ]]; then
        # Informational only. A missing unit file does not mean a clean host: a partial
        # install, or a hand-removed unit file, can leave the enablement symlink behind,
        # and skipping the disable here would leave the uninstall check failing. So fall
        # through and run the full teardown regardless.
        echo "${UNIT_NAME} unit file is not present; running teardown anyway"
    fi

    # The unit may be enabled, disabled, or already half removed; none of that should
    # stop the uninstall.
    systemctl disable --now "${UNIT_NAME}" || true

    rm -f "${UNIT_DEST}"
    rm -f "${HELPER_DEST}"

    systemctl daemon-reload
    echo "Removed ${UNIT_NAME} and ${HELPER_DEST}"
}

main "$@"
