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

# Verifies configure_spcx_cc.sh left congestion control in the requested state.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.
#
# When the feature is switched off, this verifies nothing is running and never looks for
# the DOCA binary: a node that opted out must not need the dependency installed.
#
# When it is on, an active unit is not sufficient. The daemon reports readiness in its
# own log, and initialization has been observed to take longer than eight seconds, so
# this waits for `PCC host status Active` per rail rather than trusting unit state or a
# fixed sleep.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

UNIT_NAME="doca-spcx-cc@.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
RULES_NAME="99-doca-spcx-cc.rules"
RULES_DEST="/etc/udev/rules.d/${RULES_NAME}"

IB_CLASS_DIR="${IB_CLASS_DIR:-/sys/class/infiniband}"
RAIL_GLOB="${RAIL_GLOB:-mlx5_bond_*}"
READY_PATTERN="${READY_PATTERN:-PCC host status Active}"
READY_TIMEOUT_SECS="${READY_TIMEOUT_SECS:-60}"
READY_POLL_SECS="${READY_POLL_SECS:-2}"

# Mirrors resolve_asset_dir() in configure_spcx_cc.sh.
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

    echo "${candidate}"
}

# Mirrors spcx_cc_requested() in configure_spcx_cc.sh.
spcx_cc_requested() {
    local setting
    [[ -f "${CONFIGMAP_DIR}/spcx_cc" ]] || return 0
    setting="$(xargs < "${CONFIGMAP_DIR}/spcx_cc" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Mirrors discover_rails() in configure_spcx_cc.sh, including the physfn exclusion.
# Without it a glob that matches a virtual function would make this demand a unit the
# configure step deliberately never started.
discover_rails() {
    local path name
    for path in "${IB_CLASS_DIR}/"${RAIL_GLOB}; do
        [[ -e "${path}" ]] || continue
        name="$(basename "${path}")"
        [[ -e "${path}/device/physfn" ]] && continue
        echo "${name}"
    done
}

# Mirrors owning_unit() in configure_spcx_cc.sh.
owning_unit() {
    local pid="$1" cgroup
    cgroup="$(cat "/proc/${pid}/cgroup" 2>/dev/null || true)"
    awk -F/ '$NF ~ /\.service$/ { print $NF; exit }' <<< "${cgroup}"
}

# Returns non-zero when a doca_spcx_cc process is owned by anything other than this
# package's template. Mirrors the configure-time guard so drift after config is caught.
assert_no_foreign_processes() {
    local pid unit rail found=0
    local -a pids
    mapfile -t pids < <(pgrep -x doca_spcx_cc 2>/dev/null || true)
    [[ "${#pids[@]}" -gt 0 ]] || return 0

    for pid in "${pids[@]}"; do
        unit="$(owning_unit "${pid}")"
        [[ "${unit}" == doca-spcx-cc@* ]] && continue
        rail="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n 's/.*-d[= ]\([^ ]*\).*/\1/p')"
        if [[ "${found}" -eq 0 ]]; then
            echo "ERROR: doca_spcx_cc process(es) running outside this package:"
        fi
        echo "    pid ${pid}  rail ${rail:-unknown}  owner ${unit:-<no systemd unit>}"
        found=$((found + 1))
    done

    [[ "${found}" -eq 0 ]]
}

# Wait for the daemon to report readiness in its journal. Returns non-zero on timeout.
wait_for_ready() {
    local unit="$1" elapsed=0 log
    while [[ "${elapsed}" -lt "${READY_TIMEOUT_SECS}" ]]; do
        # Captured rather than piped: `grep -q` exits at the first match, so under
        # pipefail the pipeline can return 141 and be misread as "not ready".
        log="$(journalctl -u "${unit}" --no-pager 2>/dev/null || true)"
        if grep -qF "${READY_PATTERN}" <<< "${log}"; then
            return 0
        fi
        if ! systemctl is-active --quiet "${unit}"; then
            return 1
        fi
        sleep "${READY_POLL_SECS}"
        elapsed=$((elapsed + READY_POLL_SECS))
    done
    return 1
}

verify_off() {
    # Only this package's own artifacts are asserted. Switching the feature off means
    # this package takes no part in congestion control, not that nothing else may run
    # it: processes started elsewhere are not ours to stop, so their presence is not an
    # "off" failure. The uninstall check reasons about them the same way.
    if [[ -e "${RULES_DEST}" ]]; then
        echo "ERROR: spcx_cc is off but the udev rule is still present at ${RULES_DEST}"
        exit 1
    fi

    if [[ -e "${UNIT_DEST}" ]]; then
        echo "ERROR: spcx_cc is off but the unit template is still present at ${UNIT_DEST}"
        exit 1
    fi

    local remaining
    remaining="$(systemctl list-units --all --plain --no-legend 'doca-spcx-cc@*.service' 2>/dev/null | awk '{print $1}')"
    if [[ -n "${remaining}" ]]; then
        echo "ERROR: spcx_cc is off but this package's unit(s) are still known to systemd:"
        local unit
        while read -r unit; do
            [[ -n "${unit}" ]] || continue
            echo "  ${unit}"
        done <<< "${remaining}"
        exit 1
    fi

    # Report anything else running congestion control, without failing on it. Useful
    # context when a node is deliberately excluded while the rest of a rack is not.
    local foreign
    foreign="$(pgrep -xc doca_spcx_cc 2>/dev/null || true)"
    if [[ "${foreign:-0}" -ne 0 ]]; then
        echo "Note: ${foreign} doca_spcx_cc process(es) are running from outside this package."
        echo "      They are left alone because spcx_cc is off."
    fi

    echo "Verified Spectrum-X congestion control is off"
}

verify_on() {
    local src="$1"

    if [[ ! -f "${UNIT_DEST}" ]]; then
        echo "ERROR: unit template missing at ${UNIT_DEST}"
        exit 1
    fi

    if ! cmp -s "${src}/${UNIT_NAME}" "${UNIT_DEST}"; then
        echo "ERROR: ${UNIT_DEST} does not match bundled ${src}/${UNIT_NAME}"
        exit 1
    fi

    if [[ ! -f "${RULES_DEST}" ]]; then
        echo "ERROR: udev rule missing at ${RULES_DEST}"
        exit 1
    fi

    local rails rail unit failed=0 checked=0
    rails="$(discover_rails)"

    if [[ -z "${rails}" ]]; then
        echo "ERROR: no ${RAIL_GLOB} devices found under ${IB_CLASS_DIR}; cannot run congestion control"
        exit 1
    fi

    while read -r rail; do
        [[ -n "${rail}" ]] || continue
        unit="doca-spcx-cc@${rail}.service"
        checked=$((checked + 1))

        if ! systemctl is-active --quiet "${unit}"; then
            echo "ERROR: ${unit} is not active"
            systemctl status --no-pager "${unit}" 2>&1 | head -20 || true
            failed=1
            continue
        fi

        if ! wait_for_ready "${unit}"; then
            echo "ERROR: ${unit} did not report '${READY_PATTERN}' within ${READY_TIMEOUT_SECS}s"
            journalctl -u "${unit}" --no-pager 2>/dev/null | tail -20 || true
            failed=1
            continue
        fi

        echo "Verified ${unit} is active and reporting ready"
    done <<< "${rails}"

    # Whether this package's rails are running is systemd's word, asserted above. What
    # that cannot tell us is whether something else is also running PCC, which would
    # give a rail two processes. Check for owners other than this package's template
    # rather than comparing a raw process count, so the assertion stays meaningful
    # regardless of how many rails the node has.
    if ! assert_no_foreign_processes; then
        failed=1
    fi

    [[ "${failed}" -eq 0 ]] || exit 1
    echo "Spectrum-X congestion control verified on ${checked} rail(s)"
}

main() {
    local src
    src="$(resolve_asset_dir)"

    if [[ -z "${src}" ]]; then
        echo "No bundled Spectrum-X congestion control assets for this service/accelerator; nothing to verify"
        return 0
    fi

    if ! spcx_cc_requested; then
        verify_off
        return 0
    fi

    verify_on "${src}"
}

main "$@"
