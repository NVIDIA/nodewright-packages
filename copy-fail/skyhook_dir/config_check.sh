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

# Verify the CVE-2026-31431 mitigation:
#   1. /etc/modprobe.d/disable-algif.conf exists with the expected line.
#   2. algif_aead is not currently loaded (strict; emits a loud failure
#      otherwise so operators see that the node is still vulnerable until
#      its next reboot).
#
# Set ALLOW_LOADED_MODULE=true to downgrade case (2) from failure to a
# warning. Default is "false" (declared in config.json).

set -euo pipefail

MODPROBE_FILE="/etc/modprobe.d/disable-algif.conf"
EXPECTED_LINE="install algif_aead /bin/false"
ALLOW_LOADED_MODULE="${ALLOW_LOADED_MODULE:-false}"

if [[ ! -f "${MODPROBE_FILE}" ]]; then
    echo "ERROR: ${MODPROBE_FILE} does not exist; mitigation is not applied"
    exit 1
fi

if ! grep -Fxq "${EXPECTED_LINE}" "${MODPROBE_FILE}"; then
    echo "ERROR: ${MODPROBE_FILE} exists but does not contain the expected line:"
    echo "  expected: ${EXPECTED_LINE}"
    echo "  actual contents:"
    sed 's/^/    /' "${MODPROBE_FILE}"
    exit 1
fi

echo "OK: ${MODPROBE_FILE} present with expected blacklist line"

if grep -q '^algif_aead ' /proc/modules; then
    msg="algif_aead is still loaded in the running kernel; node remains vulnerable to CVE-2026-31431 until next reboot or a successful rmmod"
    if [[ "${ALLOW_LOADED_MODULE}" == "true" ]]; then
        echo "WARNING: ${msg} (ALLOW_LOADED_MODULE=true; exiting 0)"
        exit 0
    fi
    echo "ERROR: ${msg}"
    echo "Set ALLOW_LOADED_MODULE=true on this mode in the SCR to silence this check on nodes where the loaded-module case is accepted."
    exit 1
fi

echo "OK: algif_aead is not loaded"
