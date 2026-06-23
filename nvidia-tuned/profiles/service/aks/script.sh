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

# TuneD script plugin lifecycle: start | stop [full_rollback] | verify [ignore_missing]
# https://github.com/redhat-performance/tuned/blob/v2.21.0/tuned/plugins/plugin_script.py

set -e

# Profile dir (script is in e.g. /etc/tuned/aks-{accelerator}-{intent}/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/mac-address-policy.sh"

run_bootloader() {
    if [ -f "$SCRIPT_DIR/bootloader.sh" ]; then
        "$SCRIPT_DIR/bootloader.sh"
    fi
}

cmd="${1:-}"
case "$cmd" in
    start)
        apply_network_dropin
        run_bootloader
        ;;
    stop)
        remove_network_dropin
        ;;
    verify)
        verify_network_dropin "$@"
        ;;
    *)
        echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2
        exit 1
        ;;
esac
