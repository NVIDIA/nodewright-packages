#!/bin/bash

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

# Shared helpers that write/verify/remove a systemd-networkd .link drop-in
# forcing MACAddressPolicy=none. Used on clouds (AWS, Azure) where a VM's
# NIC MAC address can change across stop/deallocate/migration, which the
# default MACAddressPolicy=persistent does not handle gracefully.
#
# Intended to be sourced by a service's script.sh; no side effects at source time.

DROPIN_FOLDER=/etc/systemd/network/99-default.link.d
CONFIG_FILE=mac-address-policy.conf
EXPECTED_NETWORK_CONTENT='[Link]
MACAddressPolicy=none
'

apply_network_dropin() {
    mkdir -p "$DROPIN_FOLDER"
    cat <<EOF > "$DROPIN_FOLDER/$CONFIG_FILE"
[Link]
MACAddressPolicy=none
EOF
}

remove_network_dropin() {
    rm -f "$DROPIN_FOLDER/$CONFIG_FILE"
    if [ -d "$DROPIN_FOLDER" ] && [ -z "$(ls -A "$DROPIN_FOLDER" 2>/dev/null)" ]; then
        rmdir "$DROPIN_FOLDER"
    fi
}

verify_network_dropin() {
    local ignore_missing=false
    [ "${2:-}" = "ignore_missing" ] && ignore_missing=true

    if [ ! -f "$DROPIN_FOLDER/$CONFIG_FILE" ]; then
        echo "Drop in file doesn't exist: $DROPIN_FOLDER/$CONFIG_FILE"
        $ignore_missing && exit 0 || exit 1
    fi
    # Use a marker so command substitution doesn't strip trailing newline from file content
    if [ "${EXPECTED_NETWORK_CONTENT}x" != "$(cat "$DROPIN_FOLDER/$CONFIG_FILE"; echo x)" ]; then
        echo "Drop in file doesn't equal expected content: $DROPIN_FOLDER/$CONFIG_FILE"
        echo "Expected: $EXPECTED_NETWORK_CONTENT"
        echo "Actual: $(cat "$DROPIN_FOLDER/$CONFIG_FILE")"
        exit 1
    fi
    exit 0
}
