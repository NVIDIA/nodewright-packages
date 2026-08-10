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

# Removes the DOCA Spectrum-X congestion control units and udev rule.
#
# Runs unconditionally rather than self-gating on the service/accelerator assets:
# uninstall must also clean up after a custom resource whose configmaps have since
# changed, so it keys on what is on the host, not on what the package currently bundles.
# Removing units that were never installed is a no-op.
#
# Never looks for the DOCA binary. Teardown has to work on a node where DOCA was removed,
# or was never installed because the feature was switched off.
#
# Only units matching this package's template are touched. Processes started by hand
# through `systemd-run` (transient doca-spcx-cc-rail* units) belong to whoever created
# them and are deliberately left alone.

set -euo pipefail

UNIT_NAME="doca-spcx-cc@.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"
RULES_NAME="99-doca-spcx-cc.rules"
RULES_DEST="/etc/udev/rules.d/${RULES_NAME}"

main() {
    # Remove the udev rule first so a device event cannot re-instantiate a unit while
    # the teardown is in progress.
    if [[ -e "${RULES_DEST}" ]]; then
        rm -f "${RULES_DEST}"
        udevadm control --reload >/dev/null 2>&1 || true
        echo "Removed ${RULES_DEST}"
    fi

    local unit stopped=0
    while read -r unit; do
        [[ -n "${unit}" ]] || continue
        systemctl disable --now "${unit}" >/dev/null 2>&1 || true
        echo "Stopped and disabled ${unit}"
        stopped=$((stopped + 1))
    done < <(systemctl list-units --all --plain --no-legend 'doca-spcx-cc@*.service' 2>/dev/null | awk '{print $1}')

    rm -f "${UNIT_DEST}"
    systemctl daemon-reload

    if [[ "${stopped}" -eq 0 ]]; then
        echo "No doca-spcx-cc@ units were present; nothing to stop"
    fi
    echo "Spectrum-X congestion control removed"
}

main "$@"
