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

# Verifies configure_bootloader.sh left a drop-in that will carry the profile's cmdline
# into the next boot.
#
# Runs before the reboot, so the running kernel still has the old command line; passing
# only means the drop-in resolves correctly. post_interrupt_bootloader_check.sh asserts
# it took effect.
#
# A non-zero exit is the signal, so no `set -e`.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"
TUNED_BOOTCMDLINE="${TUNED_BOOTCMDLINE:-/etc/tuned/bootcmdline}"

# Mirrors bootloader_enabled() in configure_bootloader.sh.
bootloader_enabled() {
    local service

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 1
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 1

    [[ -f "${PROFILES_DIR}/service/${service}/bootloader.enabled" ]]
}

# The cmdline tuned resolved from the active profile chain, or empty.
tuned_cmdline() {
    # set +u inside the subshell: these files are grub/tuned fragments that reference
    # names this script does not define.
    (
        set +u
        # shellcheck source=/dev/null
        . "${TUNED_BOOTCMDLINE}" 2>/dev/null
        printf '%s' "${TUNED_BOOT_CMDLINE:-}"
    )
}

# What grub would end up with after evaluating the drop-in, or empty.
generated_cmdline() {
    (
        set +u
        # shellcheck source=/dev/null
        . "${TUNED_GRUB_DROPIN}" 2>/dev/null
        printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    )
}

main() {
    local expected generated token tokens=() missing=()

    if ! bootloader_enabled; then
        echo "Bootloader drop-in not enabled for this service; nothing to verify"
        return 0
    fi

    if [[ ! -f "${TUNED_GRUB_DROPIN}" ]]; then
        echo "ERROR: the bootloader step was requested but no drop-in exists at ${TUNED_GRUB_DROPIN}"
        exit 1
    fi

    if [[ ! -f "${TUNED_BOOTCMDLINE}" ]]; then
        echo "ERROR: ${TUNED_BOOTCMDLINE} does not exist, so the active profile chain resolved no [bootloader] settings."
        echo "  This service exists to carry those settings onto the host, so an empty cmdline means it is doing nothing."
        echo "  Check that the accelerator's profile chain was not re-rooted onto a bootloader-free base."
        exit 1
    fi

    expected="$(tuned_cmdline)"
    if [[ -z "${expected}" ]]; then
        echo "ERROR: ${TUNED_BOOTCMDLINE} sets no TUNED_BOOT_CMDLINE, so there is nothing for the drop-in to contribute"
        exit 1
    fi

    # Evaluate the drop-in the way grub will rather than pattern-matching its text: that
    # catches a drop-in whose guard never fires or whose assignment is commented out,
    # which reads as present but contributes nothing.
    generated="$(generated_cmdline)"

    read -ra tokens <<< "${expected}"
    if (( ${#tokens[@]} == 0 )); then
        echo "ERROR: TUNED_BOOT_CMDLINE in ${TUNED_BOOTCMDLINE} holds no arguments"
        exit 1
    fi

    for token in "${tokens[@]}"; do
        case " ${generated} " in
            *" ${token} "*) ;;
            *) missing+=("${token}") ;;
        esac
    done

    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: ${TUNED_GRUB_DROPIN} does not resolve to the profile's cmdline."
        echo "  Expected to find: ${missing[*]}"
        echo "  Drop-in resolves to: ${generated}"
        exit 1
    fi

    echo "Verified ${TUNED_GRUB_DROPIN} resolves to the profile cmdline; pending reboot"
    echo "  ${expected}"
}

main "$@"
