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

# Verifies that NVIDIA tuned profiles have been properly prepared

set -x

# Source shared utilities (inherited from the tuned base image)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

# Read configmap fields
INTENT_FILE="$CONFIGMAP_DIR/intent"
ACCELERATOR_FILE="$CONFIGMAP_DIR/accelerator"
SERVICE_FILE="$CONFIGMAP_DIR/service"
TUNED_PROFILE_FILE="$CONFIGMAP_DIR/tuned_profile"

# Build the workload profile name from configmap fields
build_profile_name() {
    local intent=$1
    local accelerator=$2
    echo "nvidia-${accelerator}-${intent}"
}

# Build the final profile name: {service}-{accelerator}-{intent} when service is set
build_final_profile_name() {
    local service=$1
    local accelerator=$2
    local intent=$3
    if [ -n "$service" ]; then
        echo "${service}-${accelerator}-${intent}"
    else
        echo "nvidia-${accelerator}-${intent}"
    fi
}

# Verify common profiles are deployed
verify_common_profiles() {
    echo "Verifying common profiles in $TUNED_PROFILES_DIR..."

    if [ -d "$PROFILES_DIR/common" ]; then
        for profile_dir in "$PROFILES_DIR/common"/*/; do
            [ -d "$profile_dir" ] || continue
            profile_name=$(basename "$profile_dir")

            if [ ! -d "$TUNED_PROFILES_DIR/$profile_name" ]; then
                echo "ERROR: Common profile missing: $TUNED_PROFILES_DIR/$profile_name"
                exit 1
            fi

            if [ ! -f "$TUNED_PROFILES_DIR/$profile_name/tuned.conf" ]; then
                echo "ERROR: tuned.conf missing for common profile: $profile_name"
                exit 1
            fi

            echo "Verified common profile: $profile_name"
        done
    fi
}

# Verify ALL OS profiles are deployed
verify_os_profiles() {
    echo "Verifying OS profiles in $TUNED_PROFILES_DIR..."

    # We need to check that profiles were deployed from either OS-specific or common
    # Read OS info to determine expected source
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        local os_id="${ID:-unknown}"
        local version="${VERSION_ID:-unknown}"
        case "$os_id" in
            rhel|centos|rocky|almalinux|amzn)
                version=$(echo "$version" | cut -d. -f1)
                ;;
        esac
    fi

    local os_dir=""
    if [ -d "$PROFILES_DIR/os/$os_id/$version" ]; then
        os_dir="$PROFILES_DIR/os/$os_id/$version"
    elif [ -d "$PROFILES_DIR/os/common" ]; then
        os_dir="$PROFILES_DIR/os/common"
    fi

    if [ -n "$os_dir" ]; then
        for profile_dir in "$os_dir"/*/; do
            [ -d "$profile_dir" ] || continue
            local profile_name
            profile_name=$(basename "$profile_dir")

            if [ ! -d "$TUNED_PROFILES_DIR/$profile_name" ]; then
                echo "ERROR: OS profile directory missing: $TUNED_PROFILES_DIR/$profile_name"
                exit 1
            fi

            if [ ! -f "$TUNED_PROFILES_DIR/$profile_name/tuned.conf" ]; then
                echo "ERROR: tuned.conf missing for OS profile: $profile_name"
                exit 1
            fi

            echo "Verified OS profile: $profile_name"
        done
    fi
}

# Verify specific workload profile exists (the one constructed from intent + accelerator)
verify_constructed_profile() {
    local profile=$1

    if [ ! -d "$TUNED_PROFILES_DIR/$profile" ]; then
        echo "ERROR: Constructed profile directory missing: $TUNED_PROFILES_DIR/$profile"
        exit 1
    fi

    if [ ! -f "$TUNED_PROFILES_DIR/$profile/tuned.conf" ]; then
        echo "ERROR: tuned.conf missing for constructed profile: $profile"
        exit 1
    fi

    echo "Verified constructed profile: $profile"
}

# Verify service profile is deployed with correct include (final profile name = {service}-{accelerator}-{intent})
verify_service_profile() {
    local final_profile_name=$1
    local expected_workload_profile=$2

    if [ ! -d "$TUNED_PROFILES_DIR/$final_profile_name" ]; then
        echo "ERROR: Service profile directory missing: $TUNED_PROFILES_DIR/$final_profile_name"
        exit 1
    fi

    local service_conf="$TUNED_PROFILES_DIR/$final_profile_name/tuned.conf"
    if [ ! -f "$service_conf" ]; then
        echo "ERROR: tuned.conf missing for service profile: $final_profile_name"
        exit 1
    fi

    # Verify include line points to workload profile
    if ! grep -q "^include=$expected_workload_profile" "$service_conf"; then
        echo "ERROR: Service profile $final_profile_name does not include $expected_workload_profile"
        echo "Contents of $service_conf:"
        cat "$service_conf"
        exit 1
    fi

    echo "Verified service profile: $final_profile_name includes $expected_workload_profile"
}

# Verify tuned_profile file exists and is correct
verify_tuned_profile_file() {
    local expected_profile=$1

    if [ ! -f "$TUNED_PROFILE_FILE" ]; then
        echo "ERROR: tuned_profile file missing: $TUNED_PROFILE_FILE"
        exit 1
    fi

    local actual_profile
    actual_profile=$(xargs < "$TUNED_PROFILE_FILE")

    if [ "$actual_profile" != "$expected_profile" ]; then
        echo "ERROR: tuned_profile mismatch. Expected: $expected_profile, Got: $actual_profile"
        exit 1
    fi

    echo "Verified tuned_profile: $actual_profile"
}

main() {
    # Resolve the single profiles directory for the installed tuned version.
    resolve_tuned_profiles_dir

    # Read intent from configmap (defaults to performance)
    if [ -f "$INTENT_FILE" ]; then
        INTENT=$(xargs < "$INTENT_FILE")
    fi
    if [ -z "${INTENT:-}" ]; then
        INTENT="performance"
        echo "No intent specified, defaulting to: $INTENT"
    fi

    # Read accelerator from configmap (required)
    if [ ! -f "$ACCELERATOR_FILE" ]; then
        echo "ERROR: accelerator configmap not found at $ACCELERATOR_FILE"
        exit 1
    fi
    ACCELERATOR=$(xargs < "$ACCELERATOR_FILE")

    # Verify common profiles are deployed
    verify_common_profiles

    # Verify ALL OS profiles are deployed
    verify_os_profiles

    # When accelerator=generic, expect nvidia-generic
    if [ "$ACCELERATOR" = "generic" ]; then
        PROFILE="nvidia-generic"
        echo "Accelerator is generic, verifying profile: $PROFILE"
        verify_constructed_profile "$PROFILE"
        verify_tuned_profile_file "$PROFILE"
        echo "Profile verification complete"
        return
    fi

    # Build profile name from components
    PROFILE=$(build_profile_name "$INTENT" "$ACCELERATOR")
    echo "Verifying constructed profile: $PROFILE (intent=$INTENT, accelerator=$ACCELERATOR)"

    # Verify the constructed profile exists
    verify_constructed_profile "$PROFILE"

    # Check if service is specified
    if [ -f "$SERVICE_FILE" ]; then
        SERVICE=$(xargs < "$SERVICE_FILE")
    fi
    if [ -n "${SERVICE:-}" ]; then
        FINAL_PROFILE=$(build_final_profile_name "$SERVICE" "$ACCELERATOR" "$INTENT")
        verify_service_profile "$FINAL_PROFILE" "$PROFILE"
        verify_tuned_profile_file "$FINAL_PROFILE"
    else
        # No service, active profile is the workload profile
        verify_tuned_profile_file "$PROFILE"
    fi

    echo "Profile verification complete"
}

main "$@"
