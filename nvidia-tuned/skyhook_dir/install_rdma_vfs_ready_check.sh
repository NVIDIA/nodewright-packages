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

# Verifies install_rdma_vfs_ready.sh laid down and enabled the RDMA VF readiness unit.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly. When the service/accelerator pair ships no unit,
# there is nothing to verify and this exits 0.
#
# This runs during config-check, before the reboot, so it asserts the unit is installed
# and enabled but not that it has run. post_interrupt_rdma_vfs_ready_check.sh covers
# the post-reboot state.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

UNIT_NAME="rdma-vfs-ready.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
HELPER_NAME="wait-rdma-vfs.sh"
HELPER_DEST="/usr/local/sbin/${HELPER_NAME}"

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
    [[ -f "${candidate}/${HELPER_NAME}" ]] || return 0

    echo "${candidate}"
}

main() {
    local src
    src="$(resolve_asset_dir)"

    if [[ -z "${src}" ]]; then
        echo "No bundled RDMA VF readiness unit for this service/accelerator; nothing to verify"
        return 0
    fi

    if [[ ! -f "${HELPER_DEST}" ]]; then
        echo "ERROR: helper script missing at: ${HELPER_DEST}"
        exit 1
    fi

    if ! cmp -s "${src}/${HELPER_NAME}" "${HELPER_DEST}"; then
        echo "ERROR: ${HELPER_DEST} does not match bundled ${src}/${HELPER_NAME}"
        exit 1
    fi

    if [[ ! -x "${HELPER_DEST}" ]]; then
        echo "ERROR: ${HELPER_DEST} is not executable"
        exit 1
    fi

    if [[ ! -f "${UNIT_DEST}" ]]; then
        echo "ERROR: unit file missing at: ${UNIT_DEST}"
        exit 1
    fi

    if ! cmp -s "${src}/${UNIT_NAME}" "${UNIT_DEST}"; then
        echo "ERROR: ${UNIT_DEST} does not match bundled ${src}/${UNIT_NAME}"
        exit 1
    fi

    if ! systemctl is-enabled --quiet "${UNIT_NAME}"; then
        echo "ERROR: ${UNIT_NAME} is not enabled"
        exit 1
    fi

    echo "Verified ${UNIT_NAME} is installed and enabled"
}

main "$@"
