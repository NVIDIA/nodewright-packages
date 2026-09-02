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

# Verifies uninstall_bootloader.sh removed the grub.d drop-in.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.
#
# Asserts the drop-in is gone rather than that the cmdline is gone from the running
# kernel: the change only takes effect at the next boot, so live state still shows
# whatever the node booted with.

set -uo pipefail

TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"

DROPIN_MARKER="Managed by the nvidia-tuned Skyhook package (configure_bootloader.sh)"

main() {
    # Keys on the marker, not mere existence: a file another service owns at this path is
    # not a failed uninstall.
    if [[ -f "${TUNED_GRUB_DROPIN}" ]] && grep -qF "${DROPIN_MARKER}" "${TUNED_GRUB_DROPIN}"; then
        echo "ERROR: ${TUNED_GRUB_DROPIN} still present"
        exit 1
    fi

    echo "Verified the bootloader drop-in is removed"
}

main "$@"
