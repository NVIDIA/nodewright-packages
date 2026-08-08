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

# Waits for the Oracle Cloud Agent to create the RDMA virtual functions, then returns so
# kubelet can start. Run by rdma-vfs-ready.service.
#
# This script ALWAYS exits 0. It is ordered Before=kubelet.service, so a non-zero exit
# would strand the node outside the cluster. Waiting is best effort: if the VFs never
# appear, the node still joins and the missing capacity shows up as
# nvidia.com/mlnxnics: 0 rather than as a node that never registers.
#
# Measured on BM.GPU.GB300.4: the count went 0 -> 3 -> 4 over roughly 72 seconds, with
# the last two VFs appearing within 2 seconds of each other. A 60 second ceiling would
# be too short.

set -uo pipefail

# Number of VFs a healthy BM.GPU.GB300.4 presents.
EXPECTED_VFS="${EXPECTED_VFS:-4}"
# Overall ceiling, in seconds, before giving up and letting kubelet start.
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"
# Seconds between polls.
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-2}"
# Consecutive polls with a non-zero, unchanged count that count as settled. This is the
# degraded-NIC escape hatch: fewer VFs than expected, but the number has stopped moving.
STABLE_POLLS="${STABLE_POLLS:-5}"
# Where network interfaces are enumerated. Overridable so tests can stage a fake tree.
SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"

count_vfs() {
    local netdev total=0
    # A VF netdev has a physfn symlink back to its physical function.
    for netdev in "${SYS_CLASS_NET}"/*; do
        [[ -e "${netdev}/device/physfn" ]] || continue
        total=$((total + 1))
    done
    echo "${total}"
}

main() {
    local elapsed=0 count last_count=-1 stable=0

    while [[ "${elapsed}" -lt "${TIMEOUT_SECS}" ]]; do
        count="$(count_vfs)"

        if [[ "${count}" -ge "${EXPECTED_VFS}" ]]; then
            echo "Found ${count} RDMA VFs after ${elapsed}s; releasing kubelet"
            return 0
        fi

        if [[ "${count}" -gt 0 && "${count}" -eq "${last_count}" ]]; then
            stable=$((stable + 1))
            if [[ "${stable}" -ge "${STABLE_POLLS}" ]]; then
                echo "VF count settled at ${count} (expected ${EXPECTED_VFS}) after ${elapsed}s; releasing kubelet"
                return 0
            fi
        else
            stable=0
        fi

        last_count="${count}"
        sleep "${POLL_INTERVAL_SECS}"
        elapsed=$((elapsed + POLL_INTERVAL_SECS))
    done

    echo "Timed out after ${TIMEOUT_SECS}s with $(count_vfs) RDMA VFs (expected ${EXPECTED_VFS}); releasing kubelet anyway"
    return 0
}

main "$@"
