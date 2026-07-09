#!/usr/bin/env bash

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

# check_ib_rdma.sh: apply-check for the aks-h100 configure_ib_rdma step.
# Verifies the four config files exist and (unless SKIP_SYSTEM_OPERATIONS is set)
# the ib_umad kernel module is loaded.

set -euo pipefail

REQUIRED_FILES=(
  "/etc/modules-load.d/ib-umad.conf"
  "/etc/security/limits.d/99-ib-memlock.conf"
  "/etc/systemd/system/containerd.service.d/memlock.conf"
  "/etc/systemd/system/kubelet.service.d/memlock.conf"
)

missing=0
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "${f}" ]; then
    echo "check_ib_rdma: missing required file: ${f}" >&2
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  exit 1
fi

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  if ! lsmod | grep -q '^ib_umad'; then
    echo "check_ib_rdma: ib_umad kernel module not loaded" >&2
    exit 1
  fi
fi

echo "check_ib_rdma: ok"
