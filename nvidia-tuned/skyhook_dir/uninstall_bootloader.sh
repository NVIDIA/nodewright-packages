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

# Removes the grub.d drop-in written by configure_bootloader.sh.
#
# Runs unconditionally rather than self-gating on the service marker: uninstall must also
# clean up after a custom resource whose configmaps have since changed, so it keys on
# what is on the host. Removing a drop-in that was never written is a no-op.
#
# The drop-in only sources tuned's own file, so leaving it behind would keep applying the
# uninstalled package's cmdline on every future boot for as long as /etc/tuned/bootcmdline
# survives, with no package owning it. Removing it is the correct as-if-never-installed
# state.
#
# Scoped to the drop-in this package wrote, identified by its marker line. The eks and
# aks services write their own grub.d file from inside the tuned profile; removing that
# one is not this step's business.
#
# On SUSE there is no drop-in: tuned's own grub2 integration carries the cmdline and any
# initrd overlay, and tuned's full rollback clears them (blanks TUNED_BOOT_CMDLINE and
# TUNED_BOOT_INITRD_ADD, then tuned_params and tuned_initrd in grub.cfg) only if the daemon
# is running when it is stopped. A tuned that crashed, was stopped, or runs with
# rollback = not_on_exit leaves grub.cfg passing them after the package is gone. So this
# step does the same rollback itself and regenerates with update-bootloader --refresh,
# rather than depending on the daemon's state. Only for LOADER_TYPE grub2 and grub2-efi,
# the loaders configure_bootloader.sh accepts: any other does not boot from grub.cfg, so
# what it sets reaches no kernel and the refresh would not clear it.
#
# Takes effect on the next boot, like the change it reverts.

set -euo pipefail

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"
TUNED_BOOTCMDLINE="${TUNED_BOOTCMDLINE:-/etc/tuned/bootcmdline}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
GRUB_CFG="${GRUB_CFG:-/boot/grub2/grub.cfg}"
BOOTLOADER_SYSCONFIG="${BOOTLOADER_SYSCONFIG:-/etc/sysconfig/bootloader}"

# Mirrors DROPIN_MARKER in configure_bootloader.sh.
DROPIN_MARKER="Managed by the nvidia-tuned Skyhook package (configure_bootloader.sh)"

# Returns 0 when the drop-in exists and this package wrote it.
dropin_is_ours() {
    [[ -f "${TUNED_GRUB_DROPIN}" ]] && grep -qF "${DROPIN_MARKER}" "${TUNED_GRUB_DROPIN}"
}

# Mirrors regenerate_grub() in configure_bootloader.sh. update-grub only: the drop-in is
# written on Debian-family nodes exclusively, so that is the only place there is one to
# remove, and a grub2-mkconfig fallback here would regenerate a config that never
# referenced it.
regenerate_grub() {
    if [[ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]]; then
        echo "SKIP_SYSTEM_OPERATIONS set: not regenerating the bootloader config"
        return 0
    fi

    if ! command -v update-grub >/dev/null 2>&1; then
        echo "ERROR: update-grub is not available, so the removal cannot be applied to grub.cfg"
        return 1
    fi

    update-grub
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

# Mirrors refresh_bootloader() in configure_bootloader.sh.
refresh_bootloader() {
    if [[ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]]; then
        echo "SKIP_SYSTEM_OPERATIONS set: not regenerating the bootloader config"
        return 0
    fi

    if ! command -v update-bootloader >/dev/null 2>&1; then
        echo "ERROR: update-bootloader is not available, so grub.cfg cannot be regenerated"
        return 1
    fi

    update-bootloader --refresh
}

# The value tuned last resolved for a variable in bootcmdline, or empty.
bootcmdline_value() {
    local var="$1"
    (
        set +u
        # shellcheck source=/dev/null
        . "${TUNED_BOOTCMDLINE}" 2>/dev/null
        printf '%s' "${!var:-}"
    )
}

# The last value grub.cfg sets for a variable, or empty.
grub_cfg_value() {
    [[ -r "${GRUB_CFG}" ]] || return 0
    sed -n "s/^[[:space:]]*set[[:space:]]\{1,\}$1=\"\(.*\)\"[[:space:]]*\$/\1/p" "${GRUB_CFG}" | tail -n 1
}

# SUSE: tuned's full rollback, done here so it does not depend on the daemon running.
clear_tuned_native() {
    # A drop-in this package wrote before SUSE support: grub2-mkconfig never read it, so
    # removing it needs no regeneration, and update-grub does not exist here.
    if dropin_is_ours; then
        rm -f "${TUNED_GRUB_DROPIN}"
        echo "Removed ${TUNED_GRUB_DROPIN}; this distribution never reads it"
    fi

    local loader
    loader="$(bootloader_loader_type)"
    case "${loader}" in
        grub2 | grub2-efi) ;;
        *)
            echo "LOADER_TYPE=${loader:-<unset>} in ${BOOTLOADER_SYSCONFIG} does not boot from ${GRUB_CFG}; nothing to remove"
            return 0
            ;;
    esac

    # An initrd-only profile sets no cmdline, so all four are checked.
    local state
    state="$(bootcmdline_value TUNED_BOOT_CMDLINE)$(bootcmdline_value TUNED_BOOT_INITRD_ADD)"
    state+="$(grub_cfg_value tuned_params)$(grub_cfg_value tuned_initrd)"
    if [[ -z "${state}" ]]; then
        echo "No tuned bootloader cmdline or initrd in ${TUNED_BOOTCMDLINE} or ${GRUB_CFG}; nothing to remove"
        return 0
    fi

    # The same two variables tuned blanks. If tuned is already gone, so is 00_tuned, and
    # the refresh drops tuned_params and tuned_initrd from grub.cfg altogether.
    if [[ -f "${TUNED_BOOTCMDLINE}" ]]; then
        sed -i -E 's/^(TUNED_BOOT_CMDLINE|TUNED_BOOT_INITRD_ADD)=.*/\1=""/' "${TUNED_BOOTCMDLINE}"
    fi

    if ! refresh_bootloader; then
        echo "ERROR: could not regenerate the bootloader config; ${GRUB_CFG} still passes the profile cmdline"
        return 1
    fi

    echo "Cleared tuned's bootloader cmdline and initrd; a reboot is required to drop it"
}

main() {
    if [[ "$(bootloader_os_family)" == suse ]]; then
        clear_tuned_native
        return
    fi

    if ! dropin_is_ours; then
        echo "No nvidia-tuned bootloader drop-in at ${TUNED_GRUB_DROPIN}; nothing to remove"
        return 0
    fi

    # Back the drop-in up before removing it. If grub regeneration fails the generated
    # config still carries the profile cmdline, and leaving the source file deleted would
    # make the next uninstall report success against a node that still boots with it.
    local backup
    backup="$(mktemp)"
    cp "${TUNED_GRUB_DROPIN}" "${backup}"
    rm -f "${TUNED_GRUB_DROPIN}"

    if ! regenerate_grub; then
        mv "${backup}" "${TUNED_GRUB_DROPIN}"
        echo "ERROR: could not regenerate the bootloader config; restored ${TUNED_GRUB_DROPIN}"
        return 1
    fi

    rm -f "${backup}"
    echo "Removed ${TUNED_GRUB_DROPIN}; a reboot is required to drop the profile cmdline"
}

main "$@"
