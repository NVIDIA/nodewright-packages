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

ACCELERATOR="${1:-${ACCELERATOR:-}}"
STEP_FILES="${SKYHOOK_DIR}/skyhook_dir/steps/files/oke"

install -D -m 0644 "${STEP_FILES}/99-oci-network-mlx.rules" /etc/udev/rules.d/99-oci-network-mlx.rules
install -D -m 0755 "${STEP_FILES}/oci-create-vfs"          /usr/bin/oci-create-vfs
install -D -m 0755 "${STEP_FILES}/oci-sriov-vf-config"     /usr/bin/oci-sriov-vf-config
install -D -m 0644 "${STEP_FILES}/rdma_network.json" \
  /etc/oracle-cloud-agent/plugins/oci-hpc/oci-hpc-configure/rdma_network.json

if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  udevadm control --reload-rules || true
  udevadm trigger --subsystem-match=net || true
fi
echo "Configured OCI HPC networking helpers (accelerator=${ACCELERATOR})"
