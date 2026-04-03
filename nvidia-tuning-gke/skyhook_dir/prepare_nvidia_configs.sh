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
# Prepares tuning configmaps from baked-in profiles.
# Profile layout: profiles/{accelerator}/{intent}/ (e.g. profiles/h100/inference/).
# Reads accelerator and intent from configmap, discovers available profiles from
# the filesystem, and copies the matching profile into configmaps/.

set -e
set -u

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

ACCELERATOR_FILE="${CONFIGMAP_DIR}/accelerator"
INTENT_FILE="${CONFIGMAP_DIR}/intent"
USE_CONTAINERD=${USE_CONTAINERD:-"false"}

# Discover available accelerators (subdirs of profiles/)
available_accelerators=""
if [ -d "$PROFILES_DIR" ]; then
    for d in "$PROFILES_DIR"/*/; do
        [ -d "$d" ] || continue
        acc=$(basename "$d")
        available_accelerators="${available_accelerators} ${acc}"
    done
fi
available_accelerators=$(echo "$available_accelerators" | xargs)

# Read accelerator (required)
if [ ! -f "$ACCELERATOR_FILE" ]; then
    echo "ERROR: accelerator configmap not found at $ACCELERATOR_FILE"
    exit 1
fi
ACCELERATOR=$(cat "$ACCELERATOR_FILE" | xargs)
if [ -z "$ACCELERATOR" ]; then
    echo "ERROR: accelerator is empty"
    exit 1
fi

# Validate accelerator exists
PROFILE_ACCELERATOR_DIR="${PROFILES_DIR}/${ACCELERATOR}"
if [ ! -d "$PROFILE_ACCELERATOR_DIR" ]; then
    echo "ERROR: unknown accelerator '$ACCELERATOR'. Available:${available_accelerators:+ $available_accelerators}"
    exit 1
fi

# Discover available intents for this accelerator
available_intents=""
for d in "$PROFILE_ACCELERATOR_DIR"/*/; do
    [ -d "$d" ] || continue
    intent=$(basename "$d")
    available_intents="${available_intents} ${intent}"
done
available_intents=$(echo "$available_intents" | xargs)

# Read intent (required)
if [ ! -f "$INTENT_FILE" ]; then
    echo "ERROR: intent configmap not found at $INTENT_FILE"
    exit 1
fi
INTENT=$(cat "$INTENT_FILE" | xargs)
if [ -z "$INTENT" ]; then
    echo "ERROR: intent is empty"
    exit 1
fi

# Validate intent exists for this accelerator
PROFILE_DIR="${PROFILES_DIR}/${ACCELERATOR}/${INTENT}"
if [ ! -d "$PROFILE_DIR" ]; then
    echo "ERROR: unknown intent '$INTENT' for accelerator '$ACCELERATOR'. Available:${available_intents:+ $available_intents}"
    exit 1
fi

echo "Preparing tuning configmaps for profile: ${ACCELERATOR}/${INTENT}"

# No grub.conf on GKE (kernel cmdline is not managed via grub).

# Copy sysctl.conf (required for all profiles)
if [ -f "${PROFILE_DIR}/sysctl.conf" ]; then
    cp "${PROFILE_DIR}/sysctl.conf" "${CONFIGMAP_DIR}/sysctl.conf"
    echo "Copied sysctl.conf"
else
    echo "ERROR: required file missing: ${PROFILE_DIR}/sysctl.conf"
    exit 1
fi

# Copy service_containerd.conf only if present in profile; otherwise remove (e.g. after switching profile)
if [ -f "${PROFILE_DIR}/service_containerd.conf" ] && [ "$USE_CONTAINERD" == "true" ]; then
    cp "${PROFILE_DIR}/service_containerd.conf" "${CONFIGMAP_DIR}/service_containerd.conf"
    echo "Copied service_containerd.conf"
else
    rm -f "${CONFIGMAP_DIR}/service_containerd.conf"
fi

echo "Profile preparation complete: ${ACCELERATOR}/${INTENT}"
