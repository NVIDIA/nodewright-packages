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

# configure_ib_rdma.sh: host-level IB/RDMA setup for AKS H100 nodes.
#
# Writes the four config files needed for InfiniBand RDMA + unlimited memlock
# on containerd/kubelet. Does NOT run systemctl daemon-reload or restart any
# services — the Skyhook CR declares interrupt: { type: service, services:
# [containerd, kubelet] }, and the Skyhook agent handles daemon-reload +
# restart after this step completes.
#
# Replaces the privileged ib-node-config-aks DaemonSet from aicr.

set -euo pipefail

MODULES_LOAD_FILE="/etc/modules-load.d/ib-umad.conf"
MEMLOCK_LIMITS_FILE="/etc/security/limits.d/99-ib-memlock.conf"
CONTAINERD_DROPIN_DIR="/etc/systemd/system/containerd.service.d"
KUBELET_DROPIN_DIR="/etc/systemd/system/kubelet.service.d"
CONTAINERD_DROPIN_FILE="${CONTAINERD_DROPIN_DIR}/memlock.conf"
KUBELET_DROPIN_FILE="${KUBELET_DROPIN_DIR}/memlock.conf"

# Short-circuit: if all four files exist and ib_umad is loaded (or system
# operations are skipped in test mode), nothing to do.
if [ -f "${MODULES_LOAD_FILE}" ] \
   && [ -f "${MEMLOCK_LIMITS_FILE}" ] \
   && [ -f "${CONTAINERD_DROPIN_FILE}" ] \
   && [ -f "${KUBELET_DROPIN_FILE}" ]; then
  if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ] || lsmod | grep -q '^ib_umad'; then
    echo "configure_ib_rdma: already configured, skipping"
    exit 0
  fi
fi

echo "=== configure_ib_rdma: load kernel modules ==="
if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  modprobe ib_umad
  modprobe rdma_ucm 2>/dev/null || echo "rdma_ucm not available, continuing"
  modprobe ib_ucm 2>/dev/null || echo "ib_ucm not available, continuing"
else
  echo "SKIP_SYSTEM_OPERATIONS set: skipping modprobe"
fi

echo "=== configure_ib_rdma: persist module loading ==="
mkdir -p "$(dirname "${MODULES_LOAD_FILE}")"
printf 'ib_umad\nrdma_ucm\n' > "${MODULES_LOAD_FILE}"

echo "=== configure_ib_rdma: write memlock limits ==="
mkdir -p "$(dirname "${MEMLOCK_LIMITS_FILE}")"
printf '* - memlock unlimited\nroot - memlock unlimited\n' > "${MEMLOCK_LIMITS_FILE}"

echo "=== configure_ib_rdma: write containerd memlock drop-in ==="
mkdir -p "${CONTAINERD_DROPIN_DIR}"
printf '[Service]\nLimitMEMLOCK=infinity\n' > "${CONTAINERD_DROPIN_FILE}"

echo "=== configure_ib_rdma: write kubelet memlock drop-in ==="
mkdir -p "${KUBELET_DROPIN_DIR}"
printf '[Service]\nLimitMEMLOCK=infinity\n' > "${KUBELET_DROPIN_FILE}"

echo "=== configure_ib_rdma: done (daemon-reload + restart handled by Skyhook interrupt) ==="
