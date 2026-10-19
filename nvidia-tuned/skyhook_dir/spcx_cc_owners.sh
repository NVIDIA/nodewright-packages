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

# Shared by configure_spcx_cc.sh and configure_spcx_cc_check.sh, sourced rather than run.
# These helpers decide whether congestion control is run outside this package, so both
# scripts must reach the same answer; keeping one copy stops them drifting apart.
#
# Callers set IB_CLASS_DIR, RAIL_GLOB and PROC_DIR before sourcing.

# Report the systemd unit owning a pid, or an empty string if none does. Reads the
# cgroup rather than parsing `systemctl status`, so it works for transient units and
# for processes started outside systemd entirely.
owning_unit() {
    local pid="$1" cgroup
    # Read first, then parse. A `... | head -1` pipeline can return 141 under pipefail
    # when head exits before the reader finishes, and cgroup v1 emits many lines.
    cgroup="$(cat "${PROC_DIR}/${pid}/cgroup" 2>/dev/null || true)"
    awk -F/ '$NF ~ /\.service$/ { print $NF; exit }' <<< "${cgroup}"
}

# Echo the RDMA device a doca_spcx_cc process was started for, from its device argument:
# `-d X` as OCA 1.64 passes it, or `-d=X`, `--device X` and `--device=X`. The process's
# own arguments are read, so a wrapper that started it does not matter.
process_rail() {
    local pid="$1"
    local cmdline
    cmdline="$(tr '\0' ' ' < "${PROC_DIR}/${pid}/cmdline" 2>/dev/null || true)"
    sed -En 's/(^|.* )(-d|--device)[= ]([^ ]+).*/\3/p' <<< "${cmdline}"
}

# Returns 0 when a unit genuinely runs doca_spcx_cc rather than merely containing a
# stray copy. Some long-lived units stay active after their script ends (cloud-final,
# rc-local), and a process they left behind would never be restarted after a reboot.
# Either the process is the unit's main process, or the unit's command runs the tool.
runs_doca_spcx_cc() {
    local unit="$1" pid="$2"
    local exec_start
    [[ "$(systemctl show -p MainPID --value "${unit}" 2>/dev/null)" == "${pid}" ]] && return 0
    # Captured rather than piped into `grep -q`, which can end the pipeline with 141.
    exec_start="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null || true)"
    grep -q 'doca_spcx_cc' <<< "${exec_start}"
}

# Echo each RDMA rail on the node, one per line: the bonded PFs, named mlx5_bond_N by the
# driver or rdma_railN by oci-hpc-network-device-names 3.x, plus whatever RAIL_GLOB
# matches if it was overridden. VFs are skipped. So are other PFs, such as the front-end
# NICs (mlx5_8 and mlx5_17 on a GB300 host, behind eth0 and eth1): they carry no RDMA
# traffic, and no owner runs congestion control on them.
owned_rails() {
    local glob path
    local -a globs=("${RAIL_GLOB:-mlx5_bond_*}" "mlx5_bond_*" "rdma_rail*")
    for glob in "${globs[@]}"; do
        for path in "${IB_CLASS_DIR}/"${glob}; do
            [[ -e "${path}" ]] || continue
            [[ -e "${path}/device/physfn" ]] && continue
            basename "${path}"
        done
    done | sort -u
}

# Echo the units running doca_spcx_cc outside this package, one per line, along with
# every other instance of their templates, when those units can take over from this
# package. That needs all of:
#   - at least one doca_spcx_cc process owned by something other than this package;
#   - each such process is the main process of a persistent (non-transient) unit, or
#     that unit's command runs doca_spcx_cc;
#   - every rail (see owned_rails) has one of those processes;
#   - every instance of those units' templates that systemd knows about is active.
# Processes in this package's own template are left out: once the handover is safe,
# teardown stops them. Returns non-zero, with the reason on stderr, otherwise.
external_owners() {
    local pid unit rail owners="" covered=""
    local -a pids
    mapfile -t pids < <(pgrep -x doca_spcx_cc 2>/dev/null || true)
    [[ "${#pids[@]}" -gt 0 ]] || return 1

    for pid in "${pids[@]}"; do
        unit="$(owning_unit "${pid}")"
        [[ "${unit}" == doca-spcx-cc@* ]] && continue
        [[ -n "${unit}" ]] || return 1
        [[ "$(systemctl show -p Transient --value "${unit}" 2>/dev/null)" == "no" ]] || return 1
        runs_doca_spcx_cc "${unit}" "${pid}" || return 1
        owners+="${unit}"$'\n'
        covered+="$(process_rail "${pid}")"$'\n'
    done
    [[ -n "${owners}" ]] || return 1

    # Checked against the devices rather than the units systemd lists: an instance that
    # was never started, or stopped and was unloaded, is not listed at all.
    while read -r rail; do
        [[ -n "${rail}" ]] || continue
        if ! grep -qxF "${rail}" <<< "${covered}"; then
            echo "Not deferring: ${rail} has no congestion control process outside this package" >&2
            return 1
        fi
    done < <(owned_rails)

    # A live process per owner is not enough. An owner that runs a template per rail
    # must have every instance systemd knows about up, or a dead sibling would leave
    # its rail without congestion control after this package hands over.
    local instances="" prefix
    while read -r unit; do
        [[ -n "${unit}" ]] || continue
        if [[ "${unit}" == *@* ]]; then
            prefix="${unit%%@*}@"
            instances+="$(systemctl list-units --all --plain --no-legend "${prefix}*.service" 2>/dev/null | awk '{print $1}')"$'\n'
        fi
        instances+="${unit}"$'\n'
    done <<< "${owners}"
    instances="$(awk 'NF' <<< "${instances}" | sort -u)"

    while read -r unit; do
        if ! systemctl is-active --quiet "${unit}"; then
            echo "Not deferring: ${unit} is not active, so its rail would have no congestion control" >&2
            return 1
        fi
    done <<< "${instances}"

    echo "${instances}"
}
