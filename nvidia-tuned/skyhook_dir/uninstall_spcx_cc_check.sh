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

    local remaining
    remaining="$(systemctl list-units --all --plain --no-legend 'doca-spcx-cc@*.service' 2>/dev/null | awk '{print $1}')"
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
