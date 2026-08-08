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

# Verifies the RDMA VF readiness gate actually ran during the boot that followed the
# package's reboot interrupt.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly. When the service/accelerator pair ships no unit,
# there is nothing to verify and this exits 0.
#
# The unit is Type=oneshot with RemainAfterExit=true and always exits 0, so an active
# unit means the boot-ordering gate ran ahead of kubelet. This deliberately does not
# assert a VF count: the unit tolerates a degraded NIC by design, and failing the check
# here would quarantine a node that is otherwise fine.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

UNIT_NAME="rdma-vfs-ready.service"

# Mirrors resolve_asset_dir() in install_rdma_vfs_ready.sh.
resolve_asset_dir() {
    local service accelerator

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 0
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 0

    [[ -f "${CONFIGMAP_DIR}/accelerator" ]] || return 0
    accelerator="$(xargs < "${CONFIGMAP_DIR}/accelerator")"
    [[ -n "${accelerator}" ]] || return 0

    local candidate="${PROFILES_DIR}/service/${service}/rdma-vfs-ready-${accelerator}"
    [[ -d "${candidate}" ]] || return 0
    [[ -f "${candidate}/${UNIT_NAME}" ]] || return 0

    echo "${candidate}"
}

main() {
    local src
    src="$(resolve_asset_dir)"

    if [[ -z "${src}" ]]; then
        echo "No bundled RDMA VF readiness unit for this service/accelerator; nothing to verify"
        return 0
    fi

    if ! systemctl is-enabled --quiet "${UNIT_NAME}"; then
        echo "ERROR: ${UNIT_NAME} is not enabled"
        exit 1
    fi

    if ! systemctl is-active --quiet "${UNIT_NAME}"; then
        echo "ERROR: ${UNIT_NAME} did not run during boot"
        systemctl status --no-pager "${UNIT_NAME}" || true
        exit 1
    fi

    echo "Verified ${UNIT_NAME} ran during boot"
}

main "$@"
