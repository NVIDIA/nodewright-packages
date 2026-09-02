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
# Takes effect on the next boot, like the change it reverts.

set -euo pipefail

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"

# Mirrors DROPIN_MARKER in configure_bootloader.sh.
DROPIN_MARKER="Managed by the nvidia-tuned Skyhook package (configure_bootloader.sh)"

# Returns 0 when the drop-in exists and this package wrote it.
dropin_is_ours() {
    [[ -f "${TUNED_GRUB_DROPIN}" ]] && grep -qF "${DROPIN_MARKER}" "${TUNED_GRUB_DROPIN}"
}

# Mirrors the fallback chain in kdump's update_grub_config().
regenerate_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        if [[ -d /boot/grub2 ]]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        else
            grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        fi
    else
        echo "ERROR: neither update-grub nor grub2-mkconfig is available"
        return 1
    fi
}

main() {
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
