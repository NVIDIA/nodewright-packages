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

# Load nvidia-setup defaults and env overrides. Source this from apply.sh, apply_check.sh,
# kernel_install_check.sh, and any other script that needs SERVICE, ACCELERATOR, KERNEL, LUSTRE, EFA.
# Requires: SKYHOOK_DIR set.
# Sets and exports: CONFIGMAP_DIR, DEFAULTS_DIR, SERVICE, ACCELERATOR, COMBINATION, KERNEL, LUSTRE, EFA.

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
DEFAULTS_DIR="${SKYHOOK_DIR}/skyhook_dir/defaults"

SERVICE=$(cat "${CONFIGMAP_DIR}/service")
ACCELERATOR=$(cat "${CONFIGMAP_DIR}/accelerator")
COMBINATION="${SERVICE}-${ACCELERATOR}"
DEFAULTS_FILE="${DEFAULTS_DIR}/${COMBINATION}.conf"

if [ ! -f "${DEFAULTS_FILE}" ]; then
  echo "Unsupported combination: service=${SERVICE} accelerator=${ACCELERATOR}" >&2
  echo "Supported: $(find "${DEFAULTS_DIR}" -maxdepth 1 -name '*.conf' -exec basename {} .conf \; 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "${DEFAULTS_FILE}"

# Env overrides
[ -n "${NVIDIA_KERNEL:-}" ] && KERNEL="${NVIDIA_KERNEL}"
[ -n "${NVIDIA_LUSTRE:-}" ] && LUSTRE="${NVIDIA_LUSTRE}"
[ -n "${NVIDIA_EFA:-}" ] && EFA="${NVIDIA_EFA}"

export CONFIGMAP_DIR DEFAULTS_DIR SERVICE ACCELERATOR COMBINATION KERNEL LUSTRE EFA
