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

set -euo pipefail

# shellcheck source=../load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

NTP_SERVER="${NTP_SERVER:-169.254.169.123}"   # default: AWS IMDS NTP (eks)

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "Skipping chrony install for test environment"
else
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y chrony
fi

CHRONY_CONF=/etc/chrony/chrony.conf
mkdir -p "$(dirname "${CHRONY_CONF}")"
touch "${CHRONY_CONF}"
sed -i '/^pool/d' "${CHRONY_CONF}"
if ! grep -q "${NTP_SERVER}" "${CHRONY_CONF}"; then
  echo "server ${NTP_SERVER} prefer iburst minpoll 4 maxpoll 4" >> "${CHRONY_CONF}"
fi
echo "Configured Chrony with NTP server ${NTP_SERVER}"
