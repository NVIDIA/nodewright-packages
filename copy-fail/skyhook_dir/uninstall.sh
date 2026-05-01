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

# Revert the CVE-2026-31431 mitigation by removing the modprobe blacklist
# file. We deliberately do NOT proactively `modprobe algif_aead`: the
# kernel will autoload it on demand if anything needs it.

set -euo pipefail

MODPROBE_FILE="/etc/modprobe.d/disable-algif.conf"

if [[ -f "${MODPROBE_FILE}" ]]; then
    rm -f "${MODPROBE_FILE}"
    echo "removed ${MODPROBE_FILE}"
else
    echo "${MODPROBE_FILE} not present; nothing to remove"
fi
