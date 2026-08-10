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

# Runs DOCA Spectrum-X congestion control, one supervised process per RDMA bond.
#
# Why this exists: PCC is normally established by hand with `systemd-run`, which creates
# transient units that do not survive a reboot. This installs a template unit plus a
# udev rule instead, so each rail's process is bound to its device: it starts at boot,
# and comes back if an mlx5 driver reload removes and recreates the device.
#
# Targets are the host PF bonds (mlx5_bond_*), not the VFs that workload pods receive.
#
# This step self-gates on a bundled asset directory at:
#   ${SKYHOOK_DIR}/profiles/service/${service}/spcx-cc-${accelerator}/
# so every service/accelerator combination without it is a no-op. Today only
# service=oci, accelerator=gb300 ships one.
#
# Within that shape, the `spcx_cc` configmap key toggles the feature. It defaults to on.
# Setting it to a falsey value tears the units down and, importantly, never looks for the
# DOCA binary, so a node that has opted out does not need DOCA installed at all.
#
# `spcx_cc` is a configmap key rather than an env var on purpose: the operator diffs
# configmap keys and records them in status.ConfigUpdates, so flipping it re-runs this
# step and can drive a targeted `configInterrupts` entry. Env changes do not.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

UNIT_NAME="doca-spcx-cc@.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
RULES_NAME="99-doca-spcx-cc.rules"
RULES_DEST="/etc/udev/rules.d/${RULES_NAME}"

# Overridable so tests can point at stubs.
DOCA_SPCX_CC_BIN="${DOCA_SPCX_CC_BIN:-/opt/mellanox/doca/tools/doca_spcx_cc}"
IB_CLASS_DIR="${IB_CLASS_DIR:-/sys/class/infiniband}"
RAIL_GLOB="${RAIL_GLOB:-mlx5_bond_*}"
MLXCONFIG_BIN="${MLXCONFIG_BIN:-mlxconfig}"

# The NIC firmware setting that has to be on for a user-programmable congestion control
# program to do anything. doca_spcx_cc is exactly such a program.
#
# Only this one is required. The other congestion control knobs (ROCE_CC_STEERING_EXT,
# ROCE_ADAPTIVE_ROUTING_EN, TX_SCHEDULER_LOCALITY_MODE, PCC_INT_EN) are reported below
# but not enforced, because their required values are not
# established: PCC_INT_EN reads False on a node where congestion control works, so
# treating the observed set as mandatory would fail healthy nodes.
REQUIRED_FW_SETTING="USER_PROGRAMMABLE_CC"
REQUIRED_FW_VALUE="True(1)"
REPORTED_FW_SETTINGS="ROCE_CC_STEERING_EXT ROCE_ADAPTIVE_ROUTING_EN TX_SCHEDULER_LOCALITY_MODE PCC_INT_EN"

# Resolve the bundled asset directory for the configured service/accelerator, if any.
resolve_asset_dir() {
    local service accelerator

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 0
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 0

    [[ -f "${CONFIGMAP_DIR}/accelerator" ]] || return 0
    accelerator="$(xargs < "${CONFIGMAP_DIR}/accelerator")"
    [[ -n "${accelerator}" ]] || return 0

    local candidate="${PROFILES_DIR}/service/${service}/spcx-cc-${accelerator}"
    [[ -d "${candidate}" ]] || return 0
    [[ -f "${candidate}/${UNIT_NAME}" ]] || return 0
    [[ -f "${candidate}/${RULES_NAME}" ]] || return 0

    echo "${candidate}"
}

# Returns 0 unless the operator switched the feature off. Defaults to on.
spcx_cc_requested() {
    local setting
    [[ -f "${CONFIGMAP_DIR}/spcx_cc" ]] || return 0
    setting="$(xargs < "${CONFIGMAP_DIR}/spcx_cc" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Echo each RDMA bond device present on this node, one per line.
#
# `mlx5_bond_%d` is not incidental naming: mlx5_ib uses it precisely when hardware LAG
# is active, so the default glob is the driver declaring which devices are bonds. RDMA
# device names can still be changed, by rdma-core's persistent-naming udev rules or an
# explicit `rdma dev set <dev> name <new>`, which is what RAIL_GLOB exists for.
#
# Devices with a physfn are skipped whatever the glob says. Congestion control belongs
# on the host PFs, and a rename can leave a VF matching a pattern intended for PFs. On
# these nodes the host's own mlx5_0..3 are VFs, so a broader glob would otherwise target
# them.
discover_rails() {
    local path name
    for path in "${IB_CLASS_DIR}/"${RAIL_GLOB}; do
        [[ -e "${path}" ]] || continue
        name="$(basename "${path}")"
        if [[ -e "${path}/device/physfn" ]]; then
            echo "Skipping ${name}: it is a virtual function, not a host PF" >&2
            continue
        fi
        echo "${name}"
    done
}

# Stop and disable every instance of the template, whether or not it is ours, and remove
# the udev rule. Deliberately does not touch DOCA: teardown must work on a node that
# never had it installed.
teardown() {
    local unit
    while read -r unit; do
        [[ -n "${unit}" ]] || continue
        systemctl disable --now "${unit}" >/dev/null 2>&1 || true
        echo "Stopped and disabled ${unit}"
    done < <(systemctl list-units --all --plain --no-legend 'doca-spcx-cc@*.service' 2>/dev/null | awk '{print $1}')

    rm -f "${RULES_DEST}"
    rm -f "${UNIT_DEST}"
    systemctl daemon-reload
    udevadm control --reload >/dev/null 2>&1 || true
}

# Report the systemd unit owning a pid, or an empty string if none does. Reads the
# cgroup rather than parsing `systemctl status`, so it works for transient units and
# for processes started outside systemd entirely.
owning_unit() {
    local pid="$1" cgroup
    # Read first, then parse. A `... | head -1` pipeline can return 141 under pipefail
    # when head exits before the reader finishes, and cgroup v1 emits many lines.
    cgroup="$(cat "/proc/${pid}/cgroup" 2>/dev/null || true)"
    awk -F/ '$NF ~ /\.service$/ { print $NF; exit }' <<< "${cgroup}"
}

# A doca_spcx_cc process this package did not start is a second owner of the same rail.
# The tool requires exactly one process per rail, so refuse rather than double up.
#
# What started them is not assumed. They may be transient units from a hand-run
# `systemd-run` loop, a unit under any name, or a bare process with no unit at all, so
# the report lists what was actually found instead of naming units that may not exist.
assert_no_foreign_processes() {
    local pids pid unit rail found=0 report=""
    pids="$(pgrep -x doca_spcx_cc 2>/dev/null || true)"
    [[ -n "${pids}" ]] || return 0

    for pid in ${pids}; do
        unit="$(owning_unit "${pid}")"
        # Instances of this package's own template are not foreign.
        [[ "${unit}" == doca-spcx-cc@* ]] && continue

        rail="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n 's/.*-d[= ]\([^ ]*\).*/\1/p')"
        report+="    pid ${pid}  rail ${rail:-unknown}  owner ${unit:-<no systemd unit>}"$'\n'
        found=$((found + 1))
    done

    [[ "${found}" -gt 0 ]] || return 0

    cat <<EOF
ERROR: DOCA Spectrum-X congestion control is already running outside this package.

  Found ${found} doca_spcx_cc process(es) this package does not own:

${report}
  Starting this package's units as well would give those rails two processes, and the
  tool requires exactly one per rail.

  Remedy: stop whatever owns the processes listed above, then re-run. Where an owner is
  shown, \`systemctl stop <owner>\` is usually enough; note that units created by
  \`systemd-run\` are transient and also disappear on reboot. Alternatively set
  \`spcx_cc: "off"\` in the package configMap to leave them alone and have this package
  take no part in congestion control.
EOF
    exit 1
}

# Echo the PCI address backing an RDMA device, e.g. 0000:03:00.0.
rail_bdf() {
    local rail="$1" target
    target="$(readlink -f "${IB_CLASS_DIR}/${rail}/device" 2>/dev/null)"
    [[ -n "${target}" ]] && basename "${target}"
}

# Read one mlxconfig setting for a device. Echoes the value, or nothing if unavailable.
fw_setting() {
    local bdf="$1" key="$2" out
    # Captured rather than piped: awk exits at the first match, which can leave
    # mlxconfig writing into a closed pipe and fail the whole pipeline under pipefail.
    out="$("${MLXCONFIG_BIN}" -d "${bdf}" q 2>/dev/null || true)"
    awk -v k="${key}" '$1 == k { print $2; exit }' <<< "${out}"
}

# Congestion control needs the NIC firmware to allow a user-programmable algorithm. That
# is a prerequisite of the feature, so it is treated like the DOCA binary: required when
# the feature is on, never consulted when it is off.
assert_firmware_ready() {
    local rails="$1" rail bdf value failed=0

    if ! command -v "${MLXCONFIG_BIN}" >/dev/null 2>&1; then
        cat <<EOF
ERROR: Spectrum-X congestion control was requested but its prerequisites cannot be checked.

  ${MLXCONFIG_BIN} is not available on this node. It ships with the NVIDIA firmware
  tools (mft) and is needed to confirm the NIC allows user-programmable congestion
  control.

  Remedy: install the firmware tools, or set \`spcx_cc: "off"\` in the package configMap
  to run this node without congestion control. A node that is switched off does not need
  them.
EOF
        exit 1
    fi

    while read -r rail; do
        [[ -n "${rail}" ]] || continue
        bdf="$(rail_bdf "${rail}")"
        if [[ -z "${bdf}" ]]; then
            echo "ERROR: could not resolve a PCI address for ${rail}"
            failed=1
            continue
        fi

        value="$(fw_setting "${bdf}" "${REQUIRED_FW_SETTING}")"
        if [[ "${value}" != "${REQUIRED_FW_VALUE}" ]]; then
            echo "ERROR: ${rail} (${bdf}): ${REQUIRED_FW_SETTING} is ${value:-unreadable}, need ${REQUIRED_FW_VALUE}"
            failed=1
            continue
        fi

        # Reported for diagnostics only; see REPORTED_FW_SETTINGS above for why these
        # are not enforced.
        local extra key
        extra=""
        for key in ${REPORTED_FW_SETTINGS}; do
            extra+=" ${key}=$(fw_setting "${bdf}" "${key}")"
        done
        echo "Firmware ready on ${rail} (${bdf}): ${REQUIRED_FW_SETTING}=${value}${extra}"
    done <<< "${rails}"

    if [[ "${failed}" -ne 0 ]]; then
        cat <<EOF

  Congestion control cannot take effect while the NIC firmware disallows a
  user-programmable algorithm. The daemon would run without doing anything useful.

  ${REQUIRED_FW_SETTING} is a persistent firmware setting, not something this package
  manages. Set it with
  \`mlxconfig -d <pci-address> set ${REQUIRED_FW_SETTING}=1\` and reboot, or set
  \`spcx_cc: "off"\` in the package configMap to run this node without congestion
  control.
EOF
        exit 1
    fi
}

main() {
    local src
    src="$(resolve_asset_dir)"

    if [[ -z "${src}" ]]; then
        echo "No bundled Spectrum-X congestion control assets for this service/accelerator; nothing to do"
        return 0
    fi

    if ! spcx_cc_requested; then
        # No DOCA lookup on this path: opting out must never require the dependency.
        echo "Spectrum-X congestion control switched off via the spcx_cc configmap key; tearing down"
        teardown
        return 0
    fi

    if [[ ! -x "${DOCA_SPCX_CC_BIN}" ]]; then
        cat <<EOF
ERROR: Spectrum-X congestion control was requested but cannot be started.

  ${DOCA_SPCX_CC_BIN} is not present or not executable on this node. It ships with the
  DOCA install in the node image; a node without it cannot run congestion control.

  Impact: this node would run without congestion control while the rest of the rack has
  it. Mixed PCC state across a rack produces uneven tail latency under incast and makes
  results difficult to interpret.

  Remedy: install DOCA on this node, or set \`spcx_cc: "off"\` in the package configMap
  to run this node without congestion control. A node that is switched off does not need
  DOCA installed.
EOF
        exit 1
    fi

    assert_no_foreign_processes

    # Every prerequisite is settled before anything is written to the host. Installing
    # the udev rule first would leave a node that fails a later check with a rule that
    # can still instantiate units on the next device event.
    local rails rail started=0
    rails="$(discover_rails)"
    if [[ -z "${rails}" ]]; then
        # Bonded PFs are created by the mlx5 driver at load, so on a node that has any
        # they exist well before this runs. Finding none means the device naming is not
        # what this package expects, most likely because LAG is off. Fail loudly and
        # show what is actually there rather than installing a rule that never fires.
        echo "ERROR: no ${RAIL_GLOB} devices found under ${IB_CLASS_DIR}."
        echo "       Congestion control targets the bonded PFs. RDMA devices present:"
        local dev
        for dev in "${IB_CLASS_DIR}"/*; do
            [[ -e "${dev}" ]] || continue
            echo "         $(basename "${dev}")"
        done
        echo "       If this node names its bonds differently, override RAIL_GLOB in the"
        echo "       package env. If it has no bonded PFs, set \`spcx_cc: \"off\"\`."
        exit 1
    fi

    assert_firmware_ready "${rails}"

    install -D -m 0644 "${src}/${UNIT_NAME}" "${UNIT_DEST}"
    echo "Installed ${src}/${UNIT_NAME} -> ${UNIT_DEST}"

    install -D -m 0644 "${src}/${RULES_NAME}" "${RULES_DEST}"
    echo "Installed ${src}/${RULES_NAME} -> ${RULES_DEST}"

    systemctl daemon-reload
    udevadm control --reload >/dev/null 2>&1 || true

    # Enable so the units come back on reboot even before udev fires, and start now so
    # the change takes effect without waiting for one. Both are idempotent: systemd
    # allows only one instance per device name, which is what the tool requires.
    while read -r rail; do
        [[ -n "${rail}" ]] || continue
        systemctl enable --now "doca-spcx-cc@${rail}.service"
        echo "Started doca-spcx-cc@${rail}.service"
        started=$((started + 1))
    done <<< "${rails}"

    echo "Spectrum-X congestion control running on ${started} rail(s)"
}

main "$@"
