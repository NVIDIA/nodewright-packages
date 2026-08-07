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

# Verifies write_nccl_topo.sh installed the bundled NCCL topology file.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly. When the service/accelerator pair ships no topology
# file, there is nothing to verify and this exits 0.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

DEFAULT_TOPO_PATH="/etc/nccl/topo.xml"

# Mirrors resolve_topo_source() in write_nccl_topo.sh.
resolve_topo_source() {
    local service accelerator

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 0
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 0

    [[ -f "${CONFIGMAP_DIR}/accelerator" ]] || return 0
    accelerator="$(xargs < "${CONFIGMAP_DIR}/accelerator")"
    [[ -n "${accelerator}" ]] || return 0

    local candidate="${PROFILES_DIR}/service/${service}/nccl-topo-${accelerator}.xml"
    [[ -f "${candidate}" ]] || return 0

    echo "${candidate}"
}

main() {
    local src dest
    src="$(resolve_topo_source)"

    if [[ -z "${src}" ]]; then
        echo "No bundled NCCL topology file for this service/accelerator; nothing to verify"
        return 0
    fi

    dest="${TOPO_PATH:-${DEFAULT_TOPO_PATH}}"

    if [[ ! -f "${dest}" ]]; then
        echo "ERROR: NCCL topology file missing at: ${dest}"
        exit 1
    fi

    if ! cmp -s "${src}" "${dest}"; then
        echo "ERROR: NCCL topology file at ${dest} does not match bundled ${src}"
        exit 1
    fi

    echo "Verified NCCL topology file: ${dest}"
}

main "$@"
