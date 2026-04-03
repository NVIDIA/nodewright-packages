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


# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Verifies that prepare_nvidia_configs.sh has run: configmaps populated from
# the selected accelerator/intent profile. Uses the same profile layout
# (profiles/{accelerator}/{intent}/) and discovers available profiles from
# the filesystem.

set -e
set -u

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

ACCELERATOR_FILE="${CONFIGMAP_DIR}/accelerator"
INTENT_FILE="${CONFIGMAP_DIR}/intent"

USE_CONTAINERD=${USE_CONTAINERD:-"false"}

# Require accelerator and intent
if [ ! -f "$ACCELERATOR_FILE" ]; then
    echo "ERROR: accelerator configmap not found"
    exit 1
fi
if [ ! -f "$INTENT_FILE" ]; then
    echo "ERROR: intent configmap not found"
    exit 1
fi

ACCELERATOR=$(cat "$ACCELERATOR_FILE" | xargs)
INTENT=$(cat "$INTENT_FILE" | xargs)
if [ -z "$ACCELERATOR" ] || [ -z "$INTENT" ]; then
    echo "ERROR: accelerator and intent must be non-empty"
    exit 1
fi

# Validate profile dir exists (same layout as prepare)
PROFILE_DIR="${PROFILES_DIR}/${ACCELERATOR}/${INTENT}"
if [ ! -d "$PROFILE_DIR" ]; then
    echo "ERROR: profile not found: ${ACCELERATOR}/${INTENT}"
    exit 1
fi

# Verify configmaps were populated by prepare step (no grub on GKE)
if [ ! -f "${CONFIGMAP_DIR}/sysctl.conf" ]; then
    echo "ERROR: configmaps/sysctl.conf missing"
    exit 1
fi
# If profile has service_containerd.conf, configmaps must have it too
if [ -f "${PROFILE_DIR}/service_containerd.conf" ] && [ "$USE_CONTAINERD" == "true" ]; then
    if [ ! -f "${CONFIGMAP_DIR}/service_containerd.conf" ]; then
        echo "ERROR: configmaps/service_containerd.conf missing for profile ${ACCELERATOR}/${INTENT}"
        exit 1
    fi
fi

echo "Prepare check passed for profile: ${ACCELERATOR}/${INTENT}"
