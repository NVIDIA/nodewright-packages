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

# check_memlock.sh: post-interrupt-check for the aks-h100 combination.
# Runs after Skyhook's service interrupt has done daemon-reload + restart
# of containerd/kubelet. Verifies both services are active and that
# LimitMEMLOCK is infinity on each.

set -e

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "SKIP_SYSTEM_OPERATIONS set: skipping memlock check"
  exit 0
fi

for svc in containerd kubelet; do
  if ! systemctl is-active "${svc}" >/dev/null 2>&1; then
    echo "check_memlock: ${svc} is not active" >&2
    exit 1
  fi
  value=$(systemctl show "${svc}" -p LimitMEMLOCK --value 2>/dev/null || echo "")
  if [ "${value}" != "infinity" ]; then
    echo "check_memlock: ${svc} LimitMEMLOCK is '${value}', expected 'infinity'" >&2
    exit 1
  fi
done

echo "check_memlock: ok"
