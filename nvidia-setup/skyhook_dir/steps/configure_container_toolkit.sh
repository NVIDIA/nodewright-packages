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

# configure_container_toolkit.sh: device-isolation hardening for a node-supplied
# NVIDIA container toolkit.
#
# On nodes where the toolkit handles every container (AKS: containerd's default
# runtime is nvidia-container-runtime; OKE: an always-on CRI-O OCI hook), the
# toolkit's default accept-nvidia-visible-devices-envvar-when-unprivileged=true
# gives any unprivileged pod that sets NVIDIA_VISIBLE_DEVICES every GPU on the
# node. Refuse the env var, and accept volume-mount device requests so device
# plugins that hand out GPUs as volume mounts keep working.
#
# The toolkit re-reads its config on every container start, so no interrupt is
# needed. A node without the toolkit config (a GPU Operator toolkit owns the
# runtime, as on driverless pools) has nothing to harden, so the step no-ops.

set -euo pipefail

# shellcheck source=../utilities.sh
. "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"

NVIDIA_CTK="${NVIDIA_CTK:-nvidia-ctk}"
CONFIG_FILE="${NVIDIA_CONTAINER_RUNTIME_CONFIG:-/etc/nvidia-container-runtime/config.toml}"

ENVVAR_KEY="accept-nvidia-visible-devices-envvar-when-unprivileged"
MOUNTS_KEY="accept-nvidia-visible-devices-as-volume-mounts"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "configure_container_toolkit: ${CONFIG_FILE} not present, no node toolkit to harden, skipping"
  exit 0
fi

if toml_key_is "${CONFIG_FILE}" "${ENVVAR_KEY}" false \
   && toml_key_is "${CONFIG_FILE}" "${MOUNTS_KEY}" true; then
  echo "configure_container_toolkit: already configured, skipping"
  exit 0
fi

if ! command -v "${NVIDIA_CTK}" >/dev/null 2>&1; then
  echo "configure_container_toolkit: ${CONFIG_FILE} exists but ${NVIDIA_CTK} was not found to edit it" >&2
  exit 1
fi

echo "=== configure_container_toolkit: ${CONFIG_FILE} ==="
"${NVIDIA_CTK}" config --in-place --config="${CONFIG_FILE}" \
  --set "${ENVVAR_KEY}=false" \
  --set "${MOUNTS_KEY}=true"

echo "configure_container_toolkit: done"
