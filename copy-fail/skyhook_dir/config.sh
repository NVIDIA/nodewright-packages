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

# Apply the temporary mitigation for CVE-2026-31431 ("Copy Fail").
# See CERT-EU advisory 2026-005:
#   https://cert.europa.eu/publications/security-advisories/2026-005/
#
# Steps:
#   1. Write a modprobe blacklist that prevents algif_aead from loading.
#   2. Best-effort rmmod of any currently-loaded algif_aead. The module may
#      be in use; that is acceptable here because the blacklist file is
#      already in place for the next reboot.

set -euo pipefail

MODPROBE_FILE="/etc/modprobe.d/disable-algif.conf"
EXPECTED_LINE="install algif_aead /bin/false"

mkdir -p /etc/modprobe.d

# Write the blacklist file deterministically. Idempotent: if it already has
# the right content, the on-disk byte sequence is identical after this line.
printf '%s\n' "${EXPECTED_LINE}" > "${MODPROBE_FILE}"
echo "wrote ${MODPROBE_FILE}"

# Best-effort unload. Tolerate "module is in use" and "module not loaded".
if rmmod algif_aead 2>/dev/null; then
    echo "rmmod algif_aead: succeeded"
else
    echo "rmmod algif_aead: skipped (module not loaded or in use); blacklist will take effect on next reboot"
fi
