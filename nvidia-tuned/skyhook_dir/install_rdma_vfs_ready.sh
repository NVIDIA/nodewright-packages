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

# Installs a boot-time systemd gate that holds kubelet until the cloud provider has
# created the RDMA virtual functions.
#
# Why this exists: the sriov device plugin enumerates PCI devices once at startup and
# never rescans. On OCI GB300 the Oracle Cloud Agent creates the RDMA VFs roughly 70
# seconds after boot, so the plugin starts first, finds nothing, and the node advertises
# nvidia.com/mlnxnics: 0 permanently until the pod is deleted by hand. Ordering kubelet
# after VF creation removes the race.
#
# The unit and its helper are looked up at:
#   ${SKYHOOK_DIR}/profiles/service/${service}/rdma-vfs-ready-${accelerator}/
# so this step self-gates: every service/accelerator combination that does not ship the
# directory is a no-op. Today only service=oci, accelerator=gb300 ships one.
#
# The unit is enabled but not started. It is a boot-ordering gate, so it only has an
# effect from the next boot; activation happens through the package's reboot interrupt
# and is asserted by the post-interrupt check.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

UNIT_NAME="rdma-vfs-ready.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
HELPER_NAME="wait-rdma-vfs.sh"
HELPER_DEST="/usr/local/sbin/${HELPER_NAME}"

# Resolve the bundled asset directory for the configured service/accelerator, if any.
# Echoes the source directory on success; echoes nothing when there is nothing to install.
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
        echo "No bundled RDMA VF readiness unit for this service/accelerator; nothing to do"
        return 0
    fi

    install -D -m 0755 "${src}/${HELPER_NAME}" "${HELPER_DEST}"
    echo "Installed ${src}/${HELPER_NAME} -> ${HELPER_DEST}"

    install -D -m 0644 "${src}/${UNIT_NAME}" "${UNIT_DEST}"
    echo "Installed ${src}/${UNIT_NAME} -> ${UNIT_DEST}"

    systemctl daemon-reload

    # Enable only. Starting it now would be a no-op on a node whose VFs already exist,
    # and the point of the unit is the boot ordering it establishes for the next boot.
    systemctl enable "${UNIT_NAME}"
    echo "Enabled ${UNIT_NAME}; it takes effect on the next boot"
}

main "$@"
