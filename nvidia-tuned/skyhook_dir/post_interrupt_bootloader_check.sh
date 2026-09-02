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

# Verifies the profile's [bootloader] cmdline is live after the reboot interrupt.
#
# This is the check that makes the reboot meaningful: everything before it only proves a
# drop-in exists, and the failure it catches -- grub silently not picking the drop-in up
# -- is invisible from the config stage. The tuning the node was labelled for is simply
# absent until someone reads /proc/cmdline.
#
# A non-zero exit is the signal, so no `set -e`.

set -uo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"
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
    # set +u inside the subshell: tuned's fragment references names this script does not
    # define.
    (
        set +u
        # shellcheck source=/dev/null
        . "${TUNED_BOOTCMDLINE}" 2>/dev/null
        printf '%s' "${TUNED_BOOT_CMDLINE:-}"
    )
}

# The only place an operator will look, so name the cause and where to look next.
fail_not_applied() {
    cat <<EOF
ERROR: The tuned profile's kernel command line did not take effect on this node.

  ${1}

  Impact: the node is running without the tuning it was selected for. Depending on the
  profile that can mean no hugepages backing GPU workloads, NUMA balancing left on, or
  no serial console on a host that fails to come up.

  Where to look:
    - cat ${PROC_CMDLINE}
    - cat ${TUNED_BOOTCMDLINE}
    - cat ${TUNED_GRUB_DROPIN}
    - ls /etc/default/grub.d/   (a file sorting later can overwrite
                                 GRUB_CMDLINE_LINUX_DEFAULT wholesale)
    - grep GRUB_DEFAULT /etc/default/grub   (the node may have booted another entry)
EOF
    exit 1
}

main() {
    local expected booted token tokens=() missing=()

    if ! bootloader_enabled; then
        echo "Bootloader drop-in not enabled for this service; nothing to verify"
        return 0
    fi

    if [[ ! -f "${TUNED_BOOTCMDLINE}" ]]; then
        fail_not_applied "${TUNED_BOOTCMDLINE} does not exist, so no profile cmdline was ever resolved."
    fi

    expected="$(tuned_cmdline)"
    read -ra tokens <<< "${expected}"
    if (( ${#tokens[@]} == 0 )); then
        fail_not_applied "${TUNED_BOOTCMDLINE} sets no TUNED_BOOT_CMDLINE arguments."
    fi

    booted="$(tr -s '[:space:]' ' ' < "${PROC_CMDLINE}")"

    for token in "${tokens[@]}"; do
        case " ${booted} " in
            *" ${token} "*) ;;
            *) missing+=("${token}") ;;
        esac
    done

    if (( ${#missing[@]} > 0 )); then
        fail_not_applied "The booted kernel command line is missing: ${missing[*]}"
    fi

    echo "Verified the profile cmdline is live after reboot"
    echo "  ${expected}"
}

main "$@"
