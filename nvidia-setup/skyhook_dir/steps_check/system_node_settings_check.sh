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

# system_node_settings_check.sh: apply-check for system_node_settings step.
# Verifies the sysctl drop-in exists with the expected lines, and (unless
# SKIP_SYSTEM_OPERATIONS) that the runtime values match and UFW is masked.

set -e

SYSCTL_FILE="/etc/sysctl.d/999-nvidia-tuning.conf"
REQUIRED_LINES=(
  "fs.inotify.max_user_instances=65535"
  "fs.inotify.max_user_watches=524288"
)

if [ ! -f "${SYSCTL_FILE}" ]; then
  echo "system_node_settings_check: missing required file: ${SYSCTL_FILE}" >&2
  exit 1
fi

for line in "${REQUIRED_LINES[@]}"; do
  if ! grep -qxF "${line}" "${SYSCTL_FILE}"; then
    echo "system_node_settings_check: missing line '${line}' in ${SYSCTL_FILE}" >&2
    exit 1
  fi
done

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  if [ "$(sysctl -n fs.inotify.max_user_instances)" != "65535" ]; then
    echo "system_node_settings_check: fs.inotify.max_user_instances not 65535 at runtime" >&2
    exit 1
  fi
  if [ "$(sysctl -n fs.inotify.max_user_watches)" != "524288" ]; then
    echo "system_node_settings_check: fs.inotify.max_user_watches not 524288 at runtime" >&2
    exit 1
  fi
  if systemctl list-unit-files ufw.service >/dev/null 2>&1; then
    if [ "$(systemctl is-enabled ufw 2>/dev/null || true)" != "masked" ]; then
      echo "system_node_settings_check: ufw.service is not masked" >&2
      exit 1
    fi
  fi
fi

echo "system_node_settings_check: ok"
