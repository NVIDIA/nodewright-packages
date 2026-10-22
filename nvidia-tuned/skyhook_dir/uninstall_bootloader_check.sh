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

# Verifies uninstall_bootloader.sh removed the grub.d drop-in and, on SUSE, that grub.cfg
# no longer sets tuned_params when the node boots from it.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.
#
# Asserts the bootloader config is clean rather than that the cmdline is gone from the
# running kernel: the change only takes effect at the next boot, so live state still
# shows whatever the node booted with.

set -uo pipefail

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"

OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
GRUB_CFG="${GRUB_CFG:-/boot/grub2/grub.cfg}"
BOOTLOADER_SYSCONFIG="${BOOTLOADER_SYSCONFIG:-/etc/sysconfig/bootloader}"

DROPIN_MARKER="Managed by the nvidia-tuned Skyhook package (configure_bootloader.sh)"

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

# Mirrors grub_cfg_tuned_params() in uninstall_bootloader.sh.
grub_cfg_tuned_params() {
    [[ -r "${GRUB_CFG}" ]] || return 0
    sed -n 's/^[[:space:]]*set[[:space:]]\{1,\}tuned_params="\(.*\)"[[:space:]]*$/\1/p' "${GRUB_CFG}" | tail -n 1
}

main() {
    # Keys on the marker, not mere existence: a file another service owns at this path is
    # not a failed uninstall.
    if [[ -f "${TUNED_GRUB_DROPIN}" ]] && grep -qF "${DROPIN_MARKER}" "${TUNED_GRUB_DROPIN}"; then
        echo "ERROR: ${TUNED_GRUB_DROPIN} still present"
        exit 1
    fi

    # Runs after the tuned uninstall step too, so this also catches a grub.cfg that
    # tuned's rollback was expected to clear and did not. Only on the loaders that boot
    # from grub.cfg, as uninstall_bootloader.sh leaves it alone on any other.
    if [[ "$(bootloader_os_family)" == suse && "$(bootloader_loader_type)" =~ ^grub2(-efi)?$ ]]; then
        local params
        params="$(grub_cfg_tuned_params)"
        if [[ -n "${params}" ]]; then
            echo "ERROR: ${GRUB_CFG} still sets tuned_params, so the next boot keeps the profile cmdline:"
            echo "  ${params}"
            exit 1
        fi
    fi

    echo "Verified the bootloader drop-in is removed"
}

main "$@"
