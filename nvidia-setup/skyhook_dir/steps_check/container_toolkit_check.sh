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

# container_toolkit_check.sh: apply-check for the configure_container_toolkit
# step. Verifies both device-isolation keys are set in the toolkit config, or
# that the step had nothing to harden (no config, or no nvidia-ctk), matching
# its no-ops.

set -euo pipefail

# shellcheck source=../utilities.sh
. "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"

NVIDIA_CTK="${NVIDIA_CTK:-nvidia-ctk}"
CONFIG_FILE="${NVIDIA_CONTAINER_RUNTIME_CONFIG:-/etc/nvidia-container-runtime/config.toml}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "container_toolkit_check: ${CONFIG_FILE} not present, nothing to check"
  exit 0
fi

if ! command -v "${NVIDIA_CTK}" >/dev/null 2>&1; then
  echo "container_toolkit_check: WARNING: ${CONFIG_FILE} exists but ${NVIDIA_CTK} was not found; the step skipped it, nothing to check"
  exit 0
fi

failed=0
for kv in \
  "accept-nvidia-visible-devices-envvar-when-unprivileged=false" \
  "accept-nvidia-visible-devices-as-volume-mounts=true"; do
  if ! toml_key_is "${CONFIG_FILE}" "${kv%%=*}" "${kv#*=}"; then
    echo "container_toolkit_check: ${CONFIG_FILE} is missing '${kv%%=*} = ${kv#*=}'" >&2
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "container_toolkit_check: ok"
