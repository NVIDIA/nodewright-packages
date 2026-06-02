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

set -eo pipefail

DOCA_VERSION="${1:-${DOCA_VERSION:-3.3.0}}"
STEP_FILES="${SKYHOOK_DIR}/skyhook_dir/steps/files/oke"
export DEBIAN_FRONTEND=noninteractive

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "Skipping DOCA install for test environment (version: ${DOCA_VERSION})"
  exit 0
fi

# Idempotent: skip if DOCA/OFED already present
if command -v ofed_info >/dev/null 2>&1 && dpkg -l doca-all 2>/dev/null | grep -q '^ii'; then
  echo "DOCA already installed; skipping"
  exit 0
fi

. /etc/os-release   # ID, VERSION_ID
arch="$(dpkg --print-architecture)"   # amd64 | arm64
case "${arch}" in
  arm64) repo_arch="arm64-sbsa" ;;
  *)     repo_arch="x86_64" ;;
esac

curl -fsSL https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub \
  -o /etc/apt/trusted.gpg.d/GPG-KEY-Mellanox.pub
cat <<EOF > /etc/apt/sources.list.d/doca.list
deb [signed-by=/etc/apt/trusted.gpg.d/GPG-KEY-Mellanox.pub] https://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/${ID}${VERSION_ID}/${repo_arch}/ ./
EOF

apt-get update
# mstflint is required by Oracle Cloud Agent's Compute HPC RDMA Authentication plugin.
apt-get install -y doca-all mstflint

# Fix absolute OFED symlinks created by ofa_kernel-dkms (rc 2 == nothing to fix)
"${STEP_FILES}/fix-ofed-symlinks.sh" || rc=$?; [ "${rc:-0}" -eq 0 ] || [ "${rc:-0}" -eq 2 ]
echo "DOCA ${DOCA_VERSION} installed"
