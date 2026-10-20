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

# Verifies configure_bootloader.sh left a bootloader config that will carry the profile's
# cmdline into the next boot: the grub.d drop-in on the Debian family, the generated grub.cfg
# on SUSE.
#
# Runs before the reboot, so the running kernel still has the old command line; passing
# only means the config resolves correctly. post_interrupt_bootloader_check.sh asserts
# it took effect.
#
# A non-zero exit is the signal, so no `set -e`.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"
TUNED_BOOTCMDLINE="${TUNED_BOOTCMDLINE:-/etc/tuned/bootcmdline}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
BOOTLOADER_SYSCONFIG="${BOOTLOADER_SYSCONFIG:-/etc/sysconfig/bootloader}"
GRUB_CFG="${GRUB_CFG:-/boot/grub2/grub.cfg}"

# Mirrors bootloader_requested() in configure_bootloader.sh.
bootloader_requested() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_BOOTLOADER:-true}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Mirrors bootloader_os_family() in configure_bootloader.sh.
bootloader_os_family() {
    local ids

    [[ -r "${OS_RELEASE}" ]] || return 0
    ids="$(
        set +u
        # shellcheck source=/dev/null
        . "${OS_RELEASE}" 2>/dev/null
        printf '%s %s' "${ID:-}" "${ID_LIKE:-}"
    )"

    case " ${ids} " in
        *" debian "* | *" ubuntu "*) echo debian ;;
        " sles"* | " opensuse-leap "*) echo suse ;;
    esac
}

# Mirrors bootloader_loader_type() in configure_bootloader.sh.
bootloader_loader_type() {
    (
        set +u
        # shellcheck source=/dev/null
        . "${BOOTLOADER_SYSCONFIG}" 2>/dev/null
        printf '%s' "${LOADER_TYPE:-}"
    )
}

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

# Debian family: the drop-in must resolve to the profile's cmdline.
check_dropin() {
    local expected generated token tokens=() missing=()

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

# The last tuned_params value grub.cfg sets, or empty.
grub_cfg_tuned_params() {
    sed -n 's/^[[:space:]]*set[[:space:]]\{1,\}tuned_params="\(.*\)"[[:space:]]*$/\1/p' "${GRUB_CFG}" | tail -n 1
}

# SUSE: grub.cfg is what the next boot reads, so verify that rather than its inputs. It
# must set tuned_params to the profile's cmdline and pass $tuned_params on a linux line.
# The second half is how SLES 15 SP7 failed: tuned_params defined and never used.
check_tuned_native() {
    local loader expected defined tokens=() defined_tokens=()

    # Reachable only if configure_bootloader.sh was bypassed; it fails on these loaders.
    # Passing here could certify a stale grub.cfg the node does not boot from.
    loader="$(bootloader_loader_type)"
    case "${loader}" in
        grub2 | grub2-efi) ;;
        *)
            echo "ERROR: LOADER_TYPE=${loader:-<unset>} in ${BOOTLOADER_SYSCONFIG} does not boot from tuned's grub2 integration."
            echo "  Set CONFIGURE_BOOTLOADER=false to skip this step."
            exit 1
            ;;
    esac

    if [[ ! -f "${TUNED_BOOTCMDLINE}" ]]; then
        echo "ERROR: ${TUNED_BOOTCMDLINE} does not exist, so the active profile chain resolved no [bootloader] settings."
        echo "  This service exists to carry those settings onto the host, so an empty cmdline means it is doing nothing."
        echo "  Check that the accelerator's profile chain was not re-rooted onto a bootloader-free base."
        exit 1
    fi

    expected="$(tuned_cmdline)"
    read -ra tokens <<< "${expected}"
    if (( ${#tokens[@]} == 0 )); then
        echo "ERROR: ${TUNED_BOOTCMDLINE} sets no TUNED_BOOT_CMDLINE arguments, so there is nothing for the bootloader to carry"
        exit 1
    fi

    if [[ ! -r "${GRUB_CFG}" ]]; then
        echo "ERROR: cannot read ${GRUB_CFG}; the bootloader config was not generated"
        exit 1
    fi

    # Exact, not a subset: 00_tuned writes TUNED_BOOT_CMDLINE verbatim, so any extra
    # argument (a leftover isolcpus=, say) is stale and would still reach the kernel.
    defined="$(grub_cfg_tuned_params)"
    read -ra defined_tokens <<< "${defined}"
    if [[ "${defined_tokens[*]}" != "${tokens[*]}" ]]; then
        echo "ERROR: ${GRUB_CFG} does not set tuned_params to the profile's cmdline."
        echo "  Expected: ${tokens[*]}"
        echo "  tuned_params is: ${defined}"
        exit 1
    fi

    if ! grep -Eq '^[[:space:]]*linux(16|efi)?[[:space:]].*[$]tuned_params' "${GRUB_CFG}"; then
        echo "ERROR: ${GRUB_CFG} sets tuned_params but no linux line passes \$tuned_params,"
        echo "  so the next boot ignores the profile's cmdline. update-bootloader --refresh regenerates it."
        exit 1
    fi

    echo "Verified ${GRUB_CFG} passes the profile cmdline to the kernel; pending reboot"
    echo "  ${expected}"
}

main() {
    if ! bootloader_requested; then
        echo "Bootloader step switched off via CONFIGURE_BOOTLOADER; nothing to verify"
        return 0
    fi

    if ! bootloader_enabled; then
        echo "Bootloader drop-in not enabled for this service; nothing to verify"
        return 0
    fi

    case "$(bootloader_os_family)" in
        debian) check_dropin ;;
        suse) check_tuned_native ;;
        *)
            # Reachable only if configure_bootloader.sh was bypassed; it fails on this
            # platform. Passing here would certify a drop-in that grub never reads.
            echo "ERROR: this distribution's grub-mkconfig does not source /etc/default/grub.d/*.cfg,"
            echo "  so the drop-in cannot take effect. Set CONFIGURE_BOOTLOADER=false to skip this step."
            exit 1
            ;;
    esac
}

main "$@"
