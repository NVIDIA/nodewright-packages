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

LIMITS_FILE=/etc/security/limits.d/99-oci-hpc.conf
mkdir -p "$(dirname "${LIMITS_FILE}")"
cat <<'EOF' > "${LIMITS_FILE}"
# Managed by nvidia-setup (oke). HPC/RDMA ulimits; mirrors Oracle oci-hpc-images kernel_limits.
* soft memlock unlimited
* hard memlock unlimited
* soft rss unlimited
* hard rss unlimited
* soft core unlimited
* hard core unlimited
* soft stack unlimited
* hard stack unlimited
* soft maxlogins 8192
* hard maxlogins 8192
* soft nproc 16384
* hard nproc 16384
* soft nofile 131072
* hard nofile 131072
EOF
echo "Configured HPC ulimits at ${LIMITS_FILE}"
