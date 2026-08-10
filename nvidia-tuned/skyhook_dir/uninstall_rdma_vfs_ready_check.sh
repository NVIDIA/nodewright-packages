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

# Verifies uninstall_rdma_vfs_ready.sh removed the RDMA VF readiness gate.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.

set -uo pipefail

UNIT_NAME="rdma-vfs-ready.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
HELPER_DEST="/usr/local/sbin/wait-rdma-vfs.sh"

main() {
    if [[ -e "${UNIT_DEST}" ]]; then
        echo "ERROR: ${UNIT_DEST} still present"
        exit 1
    fi

    if [[ -e "${HELPER_DEST}" ]]; then
        echo "ERROR: ${HELPER_DEST} still present"
        exit 1
    fi

    if systemctl is-enabled --quiet "${UNIT_NAME}"; then
        echo "ERROR: ${UNIT_NAME} is still enabled"
        exit 1
    fi

    echo "Verified ${UNIT_NAME} is removed"
}

main "$@"
