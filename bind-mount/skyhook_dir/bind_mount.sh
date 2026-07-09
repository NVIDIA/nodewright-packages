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

set -euo pipefail

readonly PACKAGE_NAME="bind-mount"
readonly STATE_ROOT="/var/lib/nodewright-packages/${PACKAGE_NAME}"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOCK_TIMEOUT_SECONDS=30

MODE="${1:-}"
INSTANCE_SCOPE=""
PACKAGE_INSTANCE=""
INSTANCE_ID=""
INSTANCE_HASH=""
STATE_ROOT_LOCK_FD=""
INSTANCE_LOCK_FILE=""
INSTANCE_LOCK_FD=""
STATE_DIR=""
STATE_FILE=""
UNINSTALL_STATE_FILE=""
OWNER_MARKER=""
SYSTEMD_LOAD_STATE=""
SYSTEMD_FRAGMENT_PATH=""

SOURCE=""
TARGET=""
EXPECTED_SOURCE_FSTYPE=""
EXPECTED_SOURCE_DEVICE_PREFIX=""
UNIT_NAME=""
UNIT_FILE=""
TEMPORARY_DIRECTORY=""
TEMPORARY_FILE=""

PREVIOUS_STATE_PRESENT="false"
PREVIOUS_UNIT=""

cleanup() {
    if [[ -n "${TEMPORARY_FILE}" ]]; then
        rm -f -- "${TEMPORARY_FILE}" || true
    fi
    if [[ -n "${TEMPORARY_DIRECTORY}" ]]; then
        rmdir -- "${TEMPORARY_DIRECTORY}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

initialize_instance_identity() {
    local encoded_resource_id="${SKYHOOK_RESOURCE_ID:?SKYHOOK_RESOURCE_ID is required}"
    local resource_id package_instance package_version extra generation stable_resource_id

    # The operator contract is:
    #   {skyhook-name}-{uid}-{generation}_{package-map-key}_{version}
    # Package map keys and semantic versions cannot contain underscores. The
    # generation and version intentionally do not participate in ownership so
    # retries, config updates, and upgrades keep finding the same receipts.
    IFS=_ read -r resource_id package_instance package_version extra <<<"${encoded_resource_id}"
    [[ -n "${resource_id}" && -n "${package_instance}" && -n "${package_version}" && -z "${extra}" ]] || \
        fail "SKYHOOK_RESOURCE_ID must have the form '{skyhook-name}-{uid}-{generation}_{package-map-key}_{version}'"

    generation="${resource_id##*-}"
    stable_resource_id="${resource_id%-*}"
    [[ "${generation}" =~ ^[0-9]+$ && -n "${stable_resource_id}" && "${stable_resource_id}" != "${resource_id}" ]] || \
        fail "SKYHOOK_RESOURCE_ID does not end in a numeric Skyhook generation"
    [[ "${stable_resource_id}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || \
        fail "SKYHOOK_RESOURCE_ID contains an unsafe Skyhook name or UID"
    [[ "${package_instance}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
        fail "SKYHOOK_RESOURCE_ID contains an unsafe package map key"

    INSTANCE_SCOPE="${stable_resource_id}"
    PACKAGE_INSTANCE="${package_instance}"
    INSTANCE_ID="${INSTANCE_SCOPE}/${PACKAGE_INSTANCE}"
    INSTANCE_HASH="$(printf '%s' "${INSTANCE_ID}" | sha256sum)"
    INSTANCE_HASH="${INSTANCE_HASH%% *}"
    [[ "${INSTANCE_HASH}" =~ ^[a-f0-9]{64}$ ]] || fail "could not hash package instance identity"
    STATE_DIR="${STATE_ROOT}/${INSTANCE_HASH}"
    INSTANCE_LOCK_FILE="${STATE_ROOT}/.${INSTANCE_HASH}.lock"
    STATE_FILE="${STATE_DIR}/state"
    UNINSTALL_STATE_FILE="${STATE_DIR}/uninstall-state"
    OWNER_MARKER="# Managed by NodeWright package ${PACKAGE_NAME}; instance=${INSTANCE_ID}"
}

acquire_instance_lock() {
    local candidate=""
    local lock_status=0
    local root_lock_mode="-s"
    local root_lock_description="shared"

    [[ ! -L "${STATE_ROOT}" ]] || fail "refusing symlinked state root '${STATE_ROOT}'"
    mkdir -p "${STATE_ROOT}"
    [[ -d "${STATE_ROOT}" && ! -L "${STATE_ROOT}" ]] || \
        fail "state root '${STATE_ROOT}' is not a real directory"
    chmod 0700 "${STATE_ROOT}"

    # Every lifecycle invocation holds this stable gate for its full lifetime.
    # uninstall-check takes it exclusively so it can close and unlink the
    # per-instance lock without creating old-inode/new-inode split locking.
    exec {STATE_ROOT_LOCK_FD}<"${STATE_ROOT}"
    [[ "${STATE_ROOT}" -ef "/proc/$$/fd/${STATE_ROOT_LOCK_FD}" ]] || \
        fail "state root '${STATE_ROOT}' changed while opening it"
    if [[ "${MODE}" == "uninstall-check" ]]; then
        root_lock_mode="-x"
        root_lock_description="exclusive"
    fi
    if flock "${root_lock_mode}" -E 75 -w "${LOCK_TIMEOUT_SECONDS}" "${STATE_ROOT_LOCK_FD}"; then
        :
    else
        lock_status=$?
        if [[ "${lock_status}" == 75 ]]; then
            fail "timed out after ${LOCK_TIMEOUT_SECONDS}s acquiring ${root_lock_description} state-root lock '${STATE_ROOT}'"
        fi
        fail "flock failed with exit ${lock_status} for ${root_lock_description} state-root lock '${STATE_ROOT}'"
    fi
    [[ ! -L "${STATE_ROOT}" && "${STATE_ROOT}" -ef "/proc/$$/fd/${STATE_ROOT_LOCK_FD}" ]] || \
        fail "state root '${STATE_ROOT}' changed while waiting for its lock"

    [[ ! -L "${INSTANCE_LOCK_FILE}" ]] || \
        fail "refusing symlinked instance lock '${INSTANCE_LOCK_FILE}'"

    if [[ ! -e "${INSTANCE_LOCK_FILE}" ]]; then
        candidate="$(mktemp "${STATE_ROOT}/.lock.XXXXXX")"
        chmod 0600 "${candidate}"
        ln "${candidate}" "${INSTANCE_LOCK_FILE}" 2>/dev/null || true
        rm -f "${candidate}"
    fi

    [[ -f "${INSTANCE_LOCK_FILE}" && ! -L "${INSTANCE_LOCK_FILE}" ]] || \
        fail "instance lock '${INSTANCE_LOCK_FILE}' is not a regular file"
    exec {INSTANCE_LOCK_FD}<>"${INSTANCE_LOCK_FILE}"
    [[ ! -L "${INSTANCE_LOCK_FILE}" && "${INSTANCE_LOCK_FILE}" -ef "/proc/$$/fd/${INSTANCE_LOCK_FD}" ]] || \
        fail "instance lock '${INSTANCE_LOCK_FILE}' changed while opening it"
    if flock -x -E 75 -w "${LOCK_TIMEOUT_SECONDS}" "${INSTANCE_LOCK_FD}"; then
        :
    else
        lock_status=$?
        if [[ "${lock_status}" == 75 ]]; then
            fail "timed out after ${LOCK_TIMEOUT_SECONDS}s acquiring instance lock '${INSTANCE_LOCK_FILE}'"
        fi
        fail "flock failed with exit ${lock_status} for instance lock '${INSTANCE_LOCK_FILE}'"
    fi
    [[ ! -L "${INSTANCE_LOCK_FILE}" && "${INSTANCE_LOCK_FILE}" -ef "/proc/$$/fd/${INSTANCE_LOCK_FD}" ]] || \
        fail "instance lock '${INSTANCE_LOCK_FILE}' changed while waiting for it"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not installed on the host"
}

read_config() {
    local name="$1"
    local path="${SKYHOOK_DIR:?SKYHOOK_DIR is required}/configmaps/${name}"
    local value

    [[ -f "${path}" ]] || fail "required configMap key '${name}' is missing"
    value="$(<"${path}")"
    [[ -n "${value}" ]] || fail "configMap key '${name}' must not be empty"
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || \
        fail "configMap key '${name}' must contain exactly one line"
    printf '%s' "${value}"
}

read_optional_config() {
    local name="$1"
    local path="${SKYHOOK_DIR:?SKYHOOK_DIR is required}/configmaps/${name}"
    local value

    if [[ ! -f "${path}" ]]; then
        return 0
    fi
    value="$(<"${path}")"
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || \
        fail "configMap key '${name}' must contain at most one line"
    printf '%s' "${value}"
}

validate_path() {
    local name="$1"
    local path="$2"
    local normalized

    [[ "${path}" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
        fail "${name} must be an absolute path containing only letters, numbers, '.', '_', '-' and '/'"
    [[ "${path}" != "/" ]] || fail "${name} must not be the filesystem root"
    normalized="$(readlink -m -- "${path}")"
    [[ "${normalized}" == "${path}" ]] || \
        fail "${name} must be lexically normalized (got '${path}', expected '${normalized}')"
}

load_desired_config() {
    SOURCE="$(read_config source)"
    TARGET="$(read_config target)"
    EXPECTED_SOURCE_FSTYPE="$(read_optional_config expected-source-fstype)"
    EXPECTED_SOURCE_DEVICE_PREFIX="$(read_optional_config expected-source-device-prefix)"

    validate_path source "${SOURCE}"
    validate_path target "${TARGET}"
    [[ "${SOURCE}" != "${TARGET}" ]] || fail "source and target must be different paths"
    [[ "${TARGET}/" != "${SOURCE}/"* && "${SOURCE}/" != "${TARGET}/"* ]] || \
        fail "source and target must be disjoint paths"

    if [[ -n "${EXPECTED_SOURCE_FSTYPE}" ]]; then
        [[ "${EXPECTED_SOURCE_FSTYPE}" =~ ^[A-Za-z0-9._-]+$ ]] || \
            fail "expected-source-fstype contains unsupported characters"
    fi
    if [[ -n "${EXPECTED_SOURCE_DEVICE_PREFIX}" ]]; then
        [[ "${EXPECTED_SOURCE_DEVICE_PREFIX}" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || \
            fail "expected-source-device-prefix must be a normalized /dev path prefix"
    fi

    UNIT_NAME="$(systemd-escape --path --suffix=mount "${TARGET}")"
    [[ -n "${UNIT_NAME}" && "${UNIT_NAME}" == *.mount ]] || \
        fail "could not derive a systemd mount unit for '${TARGET}'"
    UNIT_FILE="${SYSTEMD_DIR}/${UNIT_NAME}"
}

host() {
    nsenter -t 1 -m -- "$@"
}

exact_mount_target() {
    local path="$1"
    local mount_target

    mount_target="$(host findmnt -rn -o TARGET -T "${path}" 2>/dev/null || true)"
    [[ "${mount_target}" == "${path}" ]]
}

validate_source_mount() {
    local info mount_target mount_source mount_type mount_options

    info="$(host findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS -T "${SOURCE}" 2>/dev/null || true)"
    [[ -n "${info}" ]] || fail "source '${SOURCE}' is not on a mounted filesystem"
    read -r mount_target mount_source mount_type mount_options <<<"${info}"

    [[ "${mount_target}" == "${SOURCE}" ]] || \
        fail "source '${SOURCE}' resolves to '${mount_target}', not an exact mount point"
    [[ ",${mount_options}," == *,rw,* ]] || fail "source '${SOURCE}' is not mounted read-write"

    if [[ -n "${EXPECTED_SOURCE_FSTYPE}" && "${mount_type}" != "${EXPECTED_SOURCE_FSTYPE}" ]]; then
        fail "source '${SOURCE}' has filesystem '${mount_type}', expected '${EXPECTED_SOURCE_FSTYPE}'"
    fi
    if [[ -n "${EXPECTED_SOURCE_DEVICE_PREFIX}" && "${mount_source}" != "${EXPECTED_SOURCE_DEVICE_PREFIX}"* ]]; then
        fail "source '${SOURCE}' uses '${mount_source}', expected prefix '${EXPECTED_SOURCE_DEVICE_PREFIX}'"
    fi
}

same_bind_mount() {
    local info mount_target mount_options

    info="$(host findmnt -rn -o TARGET,OPTIONS -T "${TARGET}" 2>/dev/null || true)"
    [[ -n "${info}" ]] || return 1
    read -r mount_target mount_options <<<"${info}"
    [[ "${mount_target}" == "${TARGET}" ]] || return 1
    [[ ",${mount_options}," == *,rw,* ]] || return 1
    [[ "$(host stat -Lc '%d:%i' "${SOURCE}")" == "$(host stat -Lc '%d:%i' "${TARGET}")" ]]
}

target_is_empty_directory() {
    [[ -d "${TARGET}" && ! -L "${TARGET}" ]] && \
        [[ -z "$(find "${TARGET}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

# The kubelet units in Before= are ordering hygiene for Kubernetes hosts
# (mount before workloads start on reboot); systemd ignores absent units.
render_unit() {
    local output="$1"

    cat >"${output}" <<EOF
${OWNER_MARKER}
[Unit]
Description=Bind ${SOURCE} at ${TARGET}
RequiresMountsFor=${SOURCE}
AssertDirectoryNotEmpty=!${TARGET}
Before=local-fs.target kubelet.service snap.kubelet-eks.daemon.service

[Mount]
What=${SOURCE}
Where=${TARGET}
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF
}

write_state_file() {
    local destination="$1"
    local source="$2"
    local target="$3"
    local unit="$4"
    local temporary

    [[ ! -L "${STATE_DIR}" ]] || fail "refusing symlinked state directory '${STATE_DIR}'"
    mkdir -p "${STATE_DIR}"
    [[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || \
        fail "state directory '${STATE_DIR}' is not a real directory"
    chmod 0700 "${STATE_DIR}"
    temporary="$(mktemp "${STATE_DIR}/state.XXXXXX")"
    {
        printf 'source=%s\n' "${source}"
        printf 'target=%s\n' "${target}"
        printf 'unit=%s\n' "${unit}"
        printf 'instance=%s\n' "${INSTANCE_ID}"
    } >"${temporary}"
    chmod 0600 "${temporary}"
    mv -f "${temporary}" "${destination}"
}

write_state() {
    write_state_file "${STATE_FILE}" "${SOURCE}" "${TARGET}" "${UNIT_NAME}"
    rm -f "${UNINSTALL_STATE_FILE}"
}

read_state() {
    local path="${1:-${STATE_FILE}}"
    local state_source state_target state_unit state_instance extra
    local expected_unit

    [[ ! -L "${STATE_DIR}" ]] || fail "refusing symlinked state directory '${STATE_DIR}'"
    [[ ! -L "${path}" ]] || fail "refusing symlinked state file '${path}'"
    [[ -e "${path}" ]] || return 1
    [[ -f "${path}" ]] || fail "state file '${path}' is not a regular file"
    IFS= read -r state_source <"${path}" || fail "state file '${path}' is malformed"
    IFS= read -r state_target < <(sed -n '2p' "${path}") || \
        fail "state file '${path}' is malformed"
    IFS= read -r state_unit < <(sed -n '3p' "${path}") || \
        fail "state file '${path}' is malformed"
    IFS= read -r state_instance < <(sed -n '4p' "${path}") || \
        fail "state file '${path}' is malformed"
    extra="$(sed -n '5p' "${path}")"

    [[ "${state_source}" == source=* && "${state_target}" == target=* && "${state_unit}" == unit=* && \
        "${state_instance}" == instance=* && -z "${extra}" ]] || \
        fail "state file '${path}' is malformed"

    STATE_SOURCE="${state_source#source=}"
    STATE_TARGET="${state_target#target=}"
    STATE_UNIT="${state_unit#unit=}"
    STATE_INSTANCE="${state_instance#instance=}"
    [[ "${STATE_INSTANCE}" == "${INSTANCE_ID}" ]] || \
        fail "state file '${path}' belongs to package instance '${STATE_INSTANCE}', not '${INSTANCE_ID}'"
    validate_path "state source" "${STATE_SOURCE}"
    validate_path "state target" "${STATE_TARGET}"
    expected_unit="$(systemd-escape --path --suffix=mount "${STATE_TARGET}")"
    [[ "${STATE_UNIT}" == "${expected_unit}" ]] || \
        fail "state file '${path}' names unit '${STATE_UNIT}', expected '${expected_unit}'"
}

desired_config_present() {
    [[ -f "${SKYHOOK_DIR:?SKYHOOK_DIR is required}/configmaps/source" ]]
}

list_owned_units() {
    local unit_file

    for unit_file in "${SYSTEMD_DIR}"/*.mount; do
        [[ -e "${unit_file}" && ! -L "${unit_file}" ]] || continue
        if grep -Fqx "${OWNER_MARKER}" "${unit_file}"; then
            printf '%s\n' "${unit_file##*/}"
        fi
    done
}

load_systemd_unit_state() {
    local unit="$1"
    local output line
    local saw_load_state="false"
    local saw_fragment_path="false"

    if ! output="$(systemctl show --all --property=LoadState --property=FragmentPath "${unit}" 2>/dev/null)"; then
        fail "could not inspect systemd unit '${unit}'"
    fi

    SYSTEMD_LOAD_STATE=""
    SYSTEMD_FRAGMENT_PATH=""
    while IFS= read -r line; do
        case "${line}" in
            LoadState=*)
                SYSTEMD_LOAD_STATE="${line#LoadState=}"
                saw_load_state="true"
                ;;
            FragmentPath=*)
                SYSTEMD_FRAGMENT_PATH="${line#FragmentPath=}"
                saw_fragment_path="true"
                ;;
            "")
                ;;
            *)
                fail "systemctl returned unexpected state for unit '${unit}'"
                ;;
        esac
    done <<<"${output}"
    [[ "${saw_load_state}" == "true" && "${saw_fragment_path}" == "true" && \
        -n "${SYSTEMD_LOAD_STATE}" ]] || \
        fail "systemctl returned incomplete state for unit '${unit}'"
}

require_exact_systemd_fragment() {
    local unit="$1"
    local unit_file="$2"

    load_systemd_unit_state "${unit}"
    [[ "${SYSTEMD_FRAGMENT_PATH}" == "${unit_file}" ]] || \
        fail "unit '${unit}' does not resolve to owned fragment '${unit_file}' (load state '${SYSTEMD_LOAD_STATE}', fragment '${SYSTEMD_FRAGMENT_PATH}')"
}

remove_owned_unit() {
    local unit="$1"
    local unit_file="${SYSTEMD_DIR}/${unit}"

    if [[ -L "${unit_file}" ]]; then
        fail "refusing to remove symlink '${unit_file}'"
    fi
    systemctl daemon-reload
    if [[ -e "${unit_file}" ]]; then
        grep -Fqx "${OWNER_MARKER}" "${unit_file}" || \
            fail "refusing to remove unowned unit '${unit_file}'"
        require_exact_systemd_fragment "${unit}" "${unit_file}"
        systemctl disable "${unit}" >/dev/null 2>&1 || \
            fail "could not disable owned unit '${unit}'; retaining its unit file and cleanup receipt"
        rm -f "${unit_file}"
    else
        load_systemd_unit_state "${unit}"
        # A live mount intentionally survives uninstall and may be represented
        # as a transient loaded unit with no fragment. Never disable it by
        # name; only reject a different persistent fragment.
        [[ -z "${SYSTEMD_FRAGMENT_PATH}" ]] || \
            fail "refusing to disable absent owned unit '${unit}': systemd reports load state '${SYSTEMD_LOAD_STATE}' and fragment '${SYSTEMD_FRAGMENT_PATH}'"
    fi
    systemctl daemon-reload
}

remove_all_owned_units() {
    local unit

    while IFS= read -r unit; do
        remove_owned_unit "${unit}"
    done < <(list_owned_units)
}

prepare_previous_state_reconciliation() {
    read_state || return 0

    if [[ "${STATE_SOURCE}" == "${SOURCE}" && "${STATE_TARGET}" == "${TARGET}" && \
        "${STATE_UNIT}" == "${UNIT_NAME}" ]]; then
        return 0
    fi

    if exact_mount_target "${STATE_TARGET}"; then
        fail "configuration changed while old target '${STATE_TARGET}' is still mounted; remove the package and recycle the node before changing source or target"
    fi
    PREVIOUS_STATE_PRESENT="true"
    PREVIOUS_UNIT="${STATE_UNIT}"
}

retire_previous_unit() {
    if [[ "${PREVIOUS_STATE_PRESENT}" == "true" && "${PREVIOUS_UNIT}" != "${UNIT_NAME}" ]]; then
        remove_owned_unit "${PREVIOUS_UNIT}"
    fi
}

validate_target_mount_read_write() {
    local probe="${TARGET}"
    local info mount_target mount_options

    # Resolve the nearest existing ancestor before mkdir, then check TARGET
    # itself after creation. This rejects an existing empty directory on a
    # read-only covering mount without relying on mkdir to expose the problem.
    while [[ ! -e "${probe}" ]]; do
        probe="${probe%/*}"
        [[ -n "${probe}" ]] || probe="/"
    done
    info="$(host findmnt -rn -o TARGET,OPTIONS -T "${probe}" 2>/dev/null || true)"
    [[ -n "${info}" ]] || fail "target '${TARGET}' is not on a mounted filesystem"
    read -r mount_target mount_options <<<"${info}"
    [[ ",${mount_options}," == *,rw,* ]] || \
        fail "target '${TARGET}' is covered by read-only mount '${mount_target}'"
}

check_target_safety() {
    if exact_mount_target "${TARGET}"; then
        same_bind_mount || fail "target '${TARGET}' is already a different mount"
        return 0
    fi

    if [[ -L "${TARGET}" ]]; then
        fail "target '${TARGET}' is a symlink"
    fi
    if [[ -e "${TARGET}" && ! -d "${TARGET}" ]]; then
        fail "target '${TARGET}' exists and is not a directory"
    fi
    validate_target_mount_read_write
    mkdir -p "${TARGET}"
    if exact_mount_target "${TARGET}"; then
        same_bind_mount || fail "target '${TARGET}' became a different mount while preparing it"
        return 0
    fi
    validate_target_mount_read_write
    target_is_empty_directory || \
        fail "target '${TARGET}' is not empty; refusing to hide existing data"
}

check_unit_name_safety() {
    systemctl daemon-reload
    load_systemd_unit_state "${UNIT_NAME}"
    if [[ -e "${UNIT_FILE}" ]]; then
        [[ -f "${UNIT_FILE}" && ! -L "${UNIT_FILE}" ]] || \
            fail "unit '${UNIT_FILE}' is not a regular file"
        grep -Fqx "${OWNER_MARKER}" "${UNIT_FILE}" || \
            fail "unit '${UNIT_FILE}' is owned by another package instance"
        [[ "${SYSTEMD_FRAGMENT_PATH}" == "${UNIT_FILE}" ]] || \
            fail "owned unit '${UNIT_NAME}' is not systemd's effective fragment"
    else
        [[ "${SYSTEMD_LOAD_STATE}" == "not-found" && -z "${SYSTEMD_FRAGMENT_PATH}" ]] || \
            fail "unit '${UNIT_NAME}' already exists outside '${SYSTEMD_DIR}' (load state '${SYSTEMD_LOAD_STATE}', fragment '${SYSTEMD_FRAGMENT_PATH}')"
    fi
}

check_no_fstab_owner() {
    if awk -v target="${TARGET}" '!/^[[:space:]]*#/ && NF >= 2 && $2 == target { found=1 } END { exit !found }' /etc/fstab; then
        fail "/etc/fstab already owns target '${TARGET}'"
    fi
}

install_mount() {
    load_desired_config
    validate_source_mount
    prepare_previous_state_reconciliation
    check_no_fstab_owner
    check_target_safety
    check_unit_name_safety

    [[ ! -L "${UNIT_FILE}" ]] || fail "refusing to replace symlink '${UNIT_FILE}'"
    TEMPORARY_DIRECTORY="$(mktemp -d "${SYSTEMD_DIR}/.${PACKAGE_NAME}.XXXXXX")"
    TEMPORARY_FILE="${TEMPORARY_DIRECTORY}/${UNIT_NAME}"
    render_unit "${TEMPORARY_FILE}"
    chmod 0644 "${TEMPORARY_FILE}"
    if ! systemd-analyze verify "${TEMPORARY_FILE}"; then
        fail "systemd rejected rendered unit '${UNIT_NAME}'"
    fi

    if [[ -e "${UNIT_FILE}" ]]; then
        [[ -f "${UNIT_FILE}" && ! -L "${UNIT_FILE}" ]] || \
            fail "unit '${UNIT_FILE}' is not a regular file"
        grep -Fqx "${OWNER_MARKER}" "${UNIT_FILE}" || \
            fail "unit '${UNIT_FILE}' is owned by another package instance"
        if ! cmp -s "${TEMPORARY_FILE}" "${UNIT_FILE}"; then
            mv -f -- "${TEMPORARY_FILE}" "${UNIT_FILE}"
            TEMPORARY_FILE=""
        fi
    elif ln "${TEMPORARY_FILE}" "${UNIT_FILE}"; then
        :
    else
        # Another package pod may have claimed the target after the existence
        # check. Never overwrite the winner; only accept an identical unit
        # owned by this exact Skyhook/package instance.
        [[ ! -L "${UNIT_FILE}" ]] || fail "refusing to replace symlink '${UNIT_FILE}'"
        [[ -f "${UNIT_FILE}" ]] || fail "could not claim regular unit '${UNIT_FILE}'"
        grep -Fqx "${OWNER_MARKER}" "${UNIT_FILE}" || \
            fail "unit '${UNIT_FILE}' is owned by another package instance"
        cmp -s "${TEMPORARY_FILE}" "${UNIT_FILE}" || \
            fail "unit '${UNIT_FILE}' already exists with different content"
    fi

    # Keep the last prepared definition until its verified replacement has
    # claimed a unit path. This makes rejected config changes non-destructive.
    retire_previous_unit

    # Persist ownership before systemd operations so an interrupted or failed
    # enable can still be cleaned up by ConfigMap-less uninstall on operators
    # older than v0.16.0.
    write_state
    systemctl daemon-reload
    require_exact_systemd_fragment "${UNIT_NAME}" "${UNIT_FILE}"
    [[ "${SYSTEMD_LOAD_STATE}" == "loaded" ]] || \
        fail "owned unit '${UNIT_NAME}' has load state '${SYSTEMD_LOAD_STATE}' after daemon-reload"
    systemctl enable "${UNIT_NAME}"
    if [[ -n "${TEMPORARY_FILE}" ]]; then
        rm -f -- "${TEMPORARY_FILE}"
        TEMPORARY_FILE=""
    fi
    rmdir -- "${TEMPORARY_DIRECTORY}"
    TEMPORARY_DIRECTORY=""
    echo "Prepared ${UNIT_NAME}; activate it through the package's controlled interrupt"
}

prepared_check() {
    load_desired_config
    validate_source_mount
    read_state || fail "state file '${STATE_FILE}' is missing"
    [[ "${STATE_SOURCE}" == "${SOURCE}" && "${STATE_TARGET}" == "${TARGET}" && "${STATE_UNIT}" == "${UNIT_NAME}" ]] || \
        fail "state file '${STATE_FILE}' does not match the desired mount"
    [[ -f "${UNIT_FILE}" && ! -L "${UNIT_FILE}" ]] || fail "unit '${UNIT_FILE}' is missing or is a symlink"

    TEMPORARY_FILE="$(mktemp)"
    render_unit "${TEMPORARY_FILE}"
    cmp -s "${TEMPORARY_FILE}" "${UNIT_FILE}" || fail "unit '${UNIT_FILE}' does not match desired content"
    rm -f -- "${TEMPORARY_FILE}"
    TEMPORARY_FILE=""
    systemctl is-enabled --quiet "${UNIT_NAME}" || fail "unit '${UNIT_NAME}' is not enabled"

    if exact_mount_target "${TARGET}"; then
        same_bind_mount || fail "active target '${TARGET}' does not bind the desired source"
    else
        validate_target_mount_read_write
        target_is_empty_directory || fail "inactive target '${TARGET}' is not an empty directory"
    fi
    echo "Prepared mount definition for ${SOURCE} -> ${TARGET} is valid"
}

active_check() {
    prepared_check
    systemctl is-active --quiet "${UNIT_NAME}" || fail "unit '${UNIT_NAME}' is not active"
    same_bind_mount || fail "target '${TARGET}' is not the active bind mount for '${SOURCE}'"
    echo "Active bind mount ${SOURCE} -> ${TARGET} is valid"
}

uninstall_mount() {
    local source="" target="" unit=""

    if read_state "${STATE_FILE}"; then
        source="${STATE_SOURCE}"
        target="${STATE_TARGET}"
        unit="${STATE_UNIT}"
        write_state_file "${UNINSTALL_STATE_FILE}" "${source}" "${target}" "${unit}"
        rm -f "${STATE_FILE}"
    elif read_state "${UNINSTALL_STATE_FILE}"; then
        source="${STATE_SOURCE}"
        target="${STATE_TARGET}"
        unit="${STATE_UNIT}"
    elif ! desired_config_present; then
        # No receipts and no ConfigMap: the package never installed here and
        # the operator sent a ConfigMap-less uninstall. Sweep owner-marked
        # units defensively and succeed as a no-op so removal cannot wedge.
        remove_all_owned_units
        echo "No receipts and no configuration; nothing installed by ${PACKAGE_NAME}"
        return 0
    else
        load_desired_config
        source="${SOURCE}"
        target="${TARGET}"
        unit="${UNIT_NAME}"
        write_state_file "${UNINSTALL_STATE_FILE}" "${source}" "${target}" "${unit}"
    fi

    remove_owned_unit "${unit}"
    # An interrupted config transition may leave both the previous and the
    # verified replacement unit. One instance owns only one desired mount, so
    # remove any exact-owner remainder as part of the same uninstall.
    remove_all_owned_units

    if exact_mount_target "${target}"; then
        echo "WARNING: ${target} remains mounted for workload safety; recycle the node to complete rollback"
    fi
    echo "Removed persistent definition for ${unit}"
}

cleanup_instance_state() {
    local entry name
    local -a entries=()

    [[ "${MODE}" == "uninstall-check" ]] || \
        fail "instance cleanup requires the exclusive uninstall-check gate"
    [[ ! -L "${STATE_ROOT}" && "${STATE_ROOT}" -ef "/proc/$$/fd/${STATE_ROOT_LOCK_FD}" ]] || \
        fail "state root '${STATE_ROOT}' changed before instance cleanup"
    [[ -f "${INSTANCE_LOCK_FILE}" && ! -L "${INSTANCE_LOCK_FILE}" && \
        "${INSTANCE_LOCK_FILE}" -ef "/proc/$$/fd/${INSTANCE_LOCK_FD}" ]] || \
        fail "instance lock '${INSTANCE_LOCK_FILE}' changed before cleanup"

    [[ ! -L "${STATE_DIR}" ]] || fail "refusing symlinked state directory '${STATE_DIR}'"
    if [[ -e "${STATE_DIR}" ]]; then
        [[ -d "${STATE_DIR}" ]] || fail "state directory '${STATE_DIR}' is not a directory"
        while IFS= read -r -d '' entry; do
            name="${entry##*/}"
            case "${name}" in
                state|uninstall-state|state.??????)
                    ;;
                *)
                    fail "state directory '${STATE_DIR}' contains unexpected entry '${name}'"
                    ;;
            esac
            [[ -f "${entry}" && ! -L "${entry}" ]] || \
                fail "state entry '${entry}' is not a regular file"
            entries+=("${entry}")
        done < <(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print0)

        if ((${#entries[@]} > 0)); then
            rm -f -- "${entries[@]}"
        fi
        rmdir -- "${STATE_DIR}" || fail "could not remove state directory '${STATE_DIR}'"
    fi

    # The exclusive root gate prevents another invocation from opening or
    # waiting on this inode while its pathname is removed.
    exec {INSTANCE_LOCK_FD}>&-
    INSTANCE_LOCK_FD=""
    rm -f -- "${INSTANCE_LOCK_FILE}"
    [[ ! -e "${INSTANCE_LOCK_FILE}" && ! -L "${INSTANCE_LOCK_FILE}" ]] || \
        fail "could not remove instance lock '${INSTANCE_LOCK_FILE}'"
}

uninstall_check() {
    local target="" unit=""

    if read_state "${STATE_FILE}"; then
        fail "state file '${STATE_FILE}' still exists"
    fi
    if read_state "${UNINSTALL_STATE_FILE}"; then
        target="${STATE_TARGET}"
        unit="${STATE_UNIT}"
    elif ! desired_config_present; then
        # Mirror of the uninstall no-op path: never installed, nothing to name.
        [[ -z "$(list_owned_units)" ]] || \
            fail "owner-marked mount units still exist under '${SYSTEMD_DIR}'"
        cleanup_instance_state
        echo "No receipts and no configuration; nothing installed by ${PACKAGE_NAME}"
        return 0
    else
        load_desired_config
        target="${TARGET}"
        unit="${UNIT_NAME}"
    fi

    [[ ! -e "${SYSTEMD_DIR}/${unit}" && ! -L "${SYSTEMD_DIR}/${unit}" ]] || \
        fail "unit file '${SYSTEMD_DIR}/${unit}' still exists"
    if systemctl is-enabled --quiet "${unit}" >/dev/null 2>&1; then
        fail "unit '${unit}' is still enabled"
    fi
    [[ -z "$(list_owned_units)" ]] || \
        fail "owner-marked mount units still exist under '${SYSTEMD_DIR}'"
    if exact_mount_target "${target}"; then
        echo "WARNING: ${target} remains mounted until the node is recycled"
    fi
    cleanup_instance_state
    echo "Persistent bind mount definition is removed"
}

for command_name in systemctl systemd-escape systemd-analyze nsenter findmnt stat readlink find grep awk cmp chmod flock ln mktemp sed sha256sum; do
    require_command "${command_name}"
done

initialize_instance_identity
acquire_instance_lock

case "${MODE}" in
    install)
        install_mount
        ;;
    prepared-check)
        prepared_check
        ;;
    active-check)
        active_check
        ;;
    uninstall)
        uninstall_mount
        ;;
    uninstall-check)
        uninstall_check
        ;;
    noop)
        ;;
    *)
        fail "usage: $0 {install|prepared-check|active-check|uninstall|uninstall-check|noop}"
        ;;
esac
