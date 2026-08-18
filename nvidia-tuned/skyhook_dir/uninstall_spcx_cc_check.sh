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

# Verifies uninstall_spcx_cc.sh removed this package's congestion control units.
#
# A non-zero exit is the signal here, so this script does not use `set -e`; expected
# failures are handled explicitly.
#
# Deliberately does not assert that no doca_spcx_cc process is running: hand-started
# transient units are not this package's to remove, so their presence is not an
# uninstall failure.

set -uo pipefail

UNIT_NAME="doca-spcx-cc@.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
RULES_NAME="99-doca-spcx-cc.rules"
RULES_DEST="/etc/udev/rules.d/${RULES_NAME}"

main() {
    if [[ -e "${UNIT_DEST}" ]]; then
        echo "ERROR: ${UNIT_DEST} still present"
        exit 1
    fi

    if [[ -e "${RULES_DEST}" ]]; then
        echo "ERROR: ${RULES_DEST} still present"
        exit 1
    fi

    # Ignore units whose LOAD column is not-found. Removing the template unit file is
    # exactly what makes an instance not-found, and systemd keeps the stub listed under
    # --all until it is garbage collected, so a successful uninstall leaves these behind.
    # Counting them made the check unpassable: the device units udev created still
    # reference the instances, so the stubs survive daemon-reload, and reset-failed does
    # not clear them because they are inactive/dead rather than failed. Only a unit that
    # is still loaded means the uninstall did not finish.
    local remaining
    remaining="$(systemctl list-units --all --plain --no-legend 'doca-spcx-cc@*.service' 2>/dev/null | awk '$2 != "not-found" {print $1}')"
    if [[ -n "${remaining}" ]]; then
        echo "ERROR: doca-spcx-cc@ unit(s) still known to systemd:"
        local unit
        while read -r unit; do
            [[ -n "${unit}" ]] || continue
            echo "  ${unit}"
        done <<< "${remaining}"
        exit 1
    fi

    echo "Verified Spectrum-X congestion control units are removed"
}

main "$@"
