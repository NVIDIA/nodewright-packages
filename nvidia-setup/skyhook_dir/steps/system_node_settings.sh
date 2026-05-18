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

# system_node_settings.sh: host-level sysctl tuning + UFW disable for EKS nodes.
#
# - Writes /etc/sysctl.d/999-nvidia-tuning.conf with inotify limits.
# - Applies sysctl values now (skipped under SKIP_SYSTEM_OPERATIONS).
# - Masks UFW (UFW's default DROP forward policy fights kube-proxy/VPC CNI).
#   Security is delegated to AWS Security Groups + Kubernetes NetworkPolicies.

set -e

SYSCTL_FILE="/etc/sysctl.d/999-nvidia-tuning.conf"

echo "=== system_node_settings: write ${SYSCTL_FILE} ==="
mkdir -p "$(dirname "${SYSCTL_FILE}")"
cat <<'EOF' > "${SYSCTL_FILE}"
fs.inotify.max_user_instances=65535
fs.inotify.max_user_watches=524288
EOF

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "=== system_node_settings: apply sysctl values ==="
  sysctl --system >/dev/null

  if systemctl list-unit-files ufw.service >/dev/null 2>&1; then
    echo "=== system_node_settings: mask ufw ==="
    systemctl stop ufw || true
    systemctl disable ufw || true
    systemctl mask ufw || true
  else
    echo "system_node_settings: ufw.service not present; skipping mask"
  fi
else
  echo "SKIP_SYSTEM_OPERATIONS set: skipping sysctl --system and ufw mask"
fi

echo "=== system_node_settings: done ==="
