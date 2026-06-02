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

set -e

# shellcheck source=../load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"

NTP_SERVER="${NTP_SERVER:-169.254.169.123}"

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ] && ! command -v chronyc >/dev/null 2>&1; then
  echo "chrony not installed" >&2
  exit 1
fi
if ! grep -q "${NTP_SERVER}" /etc/chrony/chrony.conf 2>/dev/null; then
  echo "Chrony config missing NTP server ${NTP_SERVER}" >&2
  exit 1
fi
exit 0
