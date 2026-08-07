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

# TuneD script plugin lifecycle: start | stop [full_rollback] | verify [ignore_missing]
# https://github.com/redhat-performance/tuned/blob/v2.21.0/tuned/plugins/plugin_script.py
#
# Only one [script] survives tuned's include chain, so this script owns both of the
# OCI profile's script-driven concerns:
#   1. the containerd LimitSTACK drop-in that every GB-class profile needs
#   2. re-enabling IPv6 on mlx5 RDMA VFs that already exist at profile activation

set -euo pipefail

# Profile dir (script is in e.g. /etc/tuned/oci-gb300-performance/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Delegate the containerd drop-in to the shared helper copied in alongside us.
run_containerd_service() {
    if [[ -x "${SCRIPT_DIR}/containerd_service.sh" ]]; then
        "${SCRIPT_DIR}/containerd_service.sh" "$@"
    fi
}

# net.ipv6.conf.all.disable_ipv6=0 does not re-enable already-disabled interfaces, so fix
# up the mlx5 VFs that exist right now; the [sysctl] defaults cover the ones created later.
reenable_rdma_vf_ipv6() {
    local netdev iface driver
    for netdev in /sys/class/net/*; do
        iface="$(basename "${netdev}")"
        [[ -e "${netdev}/device/physfn" ]] || continue
        [[ -e "${netdev}/device/driver" ]] || continue
        driver="$(basename "$(readlink -f "${netdev}/device/driver")")"
        [[ "${driver}" == "mlx5_core" ]] || continue

        echo "re-enabling IPv6 on RDMA VF ${iface}"
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" || true
        sysctl -w "net.ipv6.conf.${iface}.accept_ra=1" || true
        ip link set "${iface}" up || true
    done
}

# Confirm the RDMA IPv6 defaults are in force. The per-VF settings are deliberately not
# checked: VFs are recreated on pod handoff, so their absence is not a profile failure.
verify_rdma_ipv6() {
    [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" == "0" ]]
    [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "0" ]]
    [[ "$(sysctl -n net.ipv6.conf.default.accept_ra)" == "1" ]]
}

cmd="${1:-}"
case "${cmd}" in
    start)
        run_containerd_service start
        reenable_rdma_vf_ipv6
        ;;
    stop)
        # full_rollback (arg 2) - same unapply for this script
        run_containerd_service stop
        # The IPv6 defaults are unwound by tuned's [sysctl] rollback; the VF settings
        # are transient and disappear with the VFs themselves.
        ;;
    verify)
        run_containerd_service "$@"
        verify_rdma_ipv6
        ;;
    *)
        echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2
        exit 1
        ;;
esac
