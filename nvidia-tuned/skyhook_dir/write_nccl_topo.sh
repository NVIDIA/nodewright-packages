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

# Installs a bundled NCCL topology file onto the host when the resolved
# service/accelerator pair ships one.
#
# The file is looked up at:
#   ${SKYHOOK_DIR}/profiles/service/${service}/nccl-topo-${accelerator}.xml
# so this step self-gates: every service/accelerator combination that does not ship a
# topology file is a no-op. Today only service=oci, accelerator=gb300 ships one.
#
# The destination is ${TOPO_PATH}, set via `env` on the Skyhook custom resource, and
# defaults to /etc/nccl/topo.xml. Workloads point NCCL_TOPO_FILE at the same path.
#
# This runs as an agent-executed lifecycle step rather than from the tuned [script]
# plugin because tuned runs as a systemd daemon and does not inherit the custom
# resource's package env, so TOPO_PATH would not be visible there.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

DEFAULT_TOPO_PATH="/etc/nccl/topo.xml"

# Resolve the bundled topology file for the configured service/accelerator, if any.
# Echoes the source path on success; echoes nothing when there is nothing to install.
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
        echo "No bundled NCCL topology file for this service/accelerator; nothing to do"
        return 0
    fi

    dest="${TOPO_PATH:-${DEFAULT_TOPO_PATH}}"
    if [[ -z "${TOPO_PATH:-}" ]]; then
        echo "TOPO_PATH not set, defaulting to: ${dest}"
    fi

    if [[ "${dest}" != /* ]]; then
        echo "ERROR: TOPO_PATH must be an absolute path, got: ${dest}"
        exit 1
    fi

    mkdir -p "$(dirname "${dest}")"
    install -m 0644 "${src}" "${dest}"
    echo "Installed NCCL topology file: ${src} -> ${dest}"
}

main "$@"
