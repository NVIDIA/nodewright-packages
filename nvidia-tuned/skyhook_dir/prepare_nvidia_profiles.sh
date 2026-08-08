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

# Prepares NVIDIA tuned profiles by:
# 1. Reading intent, accelerator, and service from configmap
# 2. Constructing the workload profile name as nvidia-{accelerator}-{intent}
# 3. Final profile name: {service}-{accelerator}-{intent} when service is set, else workload profile name
# 4. Copying common base profiles to the resolved profiles directory
# 5. Selecting the appropriate OS-specific workload profiles
# 6. Setting up the service profile with dynamic include

set -xe
set -u

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

# Detect OS from /etc/os-release
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        # Get major.minor version (e.g., "24.04" from "24.04.1")
        VERSION="${VERSION_ID:-unknown}"
        # For RHEL-like systems, just use the major version
        case "$OS_ID" in
            rhel|centos|rocky|almalinux|amzn)
                VERSION=$(echo "$VERSION" | cut -d. -f1)
                ;;
        esac
        echo "Detected OS: $OS_ID $VERSION"
    else
        echo "ERROR: /etc/os-release not found"
        exit 1
    fi
}

# Build the profile name from configmap fields
build_profile_name() {
    local intent=$1
    local accelerator=$2
    echo "nvidia-${accelerator}-${intent}"
}

# Copy common base profiles to the resolved tuned profiles dir
deploy_common_profiles() {
    echo "Deploying common profiles to $TUNED_PROFILES_DIR..."

    if [ -d "$PROFILES_DIR/common" ]; then
        for profile_dir in "$PROFILES_DIR/common"/*/; do
            [ -d "$profile_dir" ] || continue
            profile_name=$(basename "$profile_dir")
            rm -rf "${TUNED_PROFILES_DIR:?}/$profile_name"
            cp -rL "$profile_dir" "$TUNED_PROFILES_DIR/$profile_name"
            echo "Deployed common profile: $profile_name"
        done
    else
        echo "WARNING: No common profiles directory found at $PROFILES_DIR/common"
    fi
}

# Deploy ALL OS-specific workload profiles
deploy_os_profiles() {
    echo "Deploying OS profiles to $TUNED_PROFILES_DIR..."

    mkdir -p "$TUNED_PROFILES_DIR"

    # Track what this function deploys. Since all profiles now share one
    # directory (common base profiles are deployed here first), checking the
    # directory's overall contents no longer tells us whether OS profiles were
    # found, so track it explicitly instead.
    local deployed_any=false

    # Always deploy from os/common first (provides all profiles)
    if [ -d "$PROFILES_DIR/os/common" ]; then
        echo "Deploying common OS profiles from: os/common"
        for profile_dir in "$PROFILES_DIR/os/common"/*/; do
            [ -d "$profile_dir" ] || continue
            profile_name=$(basename "$profile_dir")
            rm -rf "${TUNED_PROFILES_DIR:?}/$profile_name"
            cp -rL "$profile_dir" "$TUNED_PROFILES_DIR/$profile_name"
            deployed_any=true
            echo "Deployed common profile: $profile_name"
        done
    else
        echo "WARNING: No common OS profiles found at $PROFILES_DIR/os/common"
    fi

    # Then overlay OS-specific profiles (these override common ones)
    if [ -d "$PROFILES_DIR/os/$OS_ID/$VERSION" ]; then
        echo "Overlaying OS-specific profiles from: $OS_ID/$VERSION"
        for profile_dir in "$PROFILES_DIR/os/$OS_ID/$VERSION"/*/; do
            [ -d "$profile_dir" ] || continue
            profile_name=$(basename "$profile_dir")
            rm -rf "${TUNED_PROFILES_DIR:?}/$profile_name"
            cp -rL "$profile_dir" "$TUNED_PROFILES_DIR/$profile_name"
            deployed_any=true
            echo "Deployed OS-specific profile: $profile_name"
        done
    fi

    # Verify this function actually deployed at least one OS profile
    if [ "$deployed_any" = false ]; then
        echo "ERROR: No OS profiles found in os/$OS_ID/$VERSION/ or os/common/"
        exit 1
    fi
}

# Validate that the requested profile exists
validate_profile() {
    local profile=$1

    if [ ! -d "$TUNED_PROFILES_DIR/$profile" ]; then
        echo "ERROR: Constructed profile '$profile' not found in $TUNED_PROFILES_DIR"
        echo "  intent=$INTENT, accelerator=$ACCELERATOR -> profile=$profile"
        echo "Available profiles:"
        ls -1 "$TUNED_PROFILES_DIR" 2>/dev/null || echo "  (none)"
        exit 1
    fi

    echo "Validated profile exists: $profile"
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

# Deploy service profile with dynamic include (into directory named {service}-{accelerator}-{intent})
deploy_service_profile() {
    local service=$1
    local profile=$2
    local final_profile_name=$3
    local service_dir="$PROFILES_DIR/service/$service"

    if [ ! -d "$service_dir" ]; then
        echo "ERROR: Service '$service' not found at $service_dir"
        exit 1
    fi

    # Check if there's a service-specific version of the profile
    local service_specific_profile="$service_dir/${profile}.conf"
    if [ -f "$service_specific_profile" ]; then
        echo "Found service-specific profile: $service_specific_profile"
        # Deploy the service-specific profile to /etc/tuned/
        mkdir -p "$TUNED_PROFILES_DIR/$profile"
        cp "$service_specific_profile" "$TUNED_PROFILES_DIR/$profile/tuned.conf"
        echo "Deployed service-specific profile: $profile"
        # Use the service-specific profile in the include
        local profile_to_include="$profile"
    else
        # Use the regular profile
        local profile_to_include="$profile"
    fi

    # Create service profile directory (final profile name = {service}-{accelerator}-{intent}); remove first so changed content is applied
    rm -rf "${TUNED_PROFILES_DIR:?}/$final_profile_name"
    mkdir -p "$TUNED_PROFILES_DIR/$final_profile_name"

    # Copy shared helper scripts from profiles/service/common/ into the final profile dir.
    # Each service's script.sh sources these helpers from its own profile dir ($SCRIPT_DIR).
    local common_dir="$PROFILES_DIR/service/common"
    if [ -d "$common_dir" ]; then
        for helper in "$common_dir"/*.sh; do
            [ -f "$helper" ] || continue
            local helper_name
            helper_name=$(basename "$helper")
            cp "$helper" "$TUNED_PROFILES_DIR/$final_profile_name/$helper_name"
            chmod +x "$TUNED_PROFILES_DIR/$final_profile_name/$helper_name"
            echo "Copied shared helper: $helper_name"
        done
    fi

    # Copy template and inject include line
    local template="$service_dir/tuned.conf.template"
    if [ -f "$template" ]; then
        # Insert include= line after [main]
        sed "s/^\[main\]/[main]\ninclude=$profile_to_include/" "$template" | tee "$TUNED_PROFILES_DIR/$final_profile_name/tuned.conf" > /dev/null
        echo "Created service profile: $final_profile_name with include=$profile_to_include"
    else
        echo "ERROR: Service template not found: $template"
        exit 1
    fi

    # Copy any additional files (scripts, etc.)
    for file in "$service_dir"/*; do
        [ -f "$file" ] || continue
        filename=$(basename "$file")
        [ "$filename" = "tuned.conf.template" ] && continue
        [[ "$filename" == *.conf ]] && continue  # Skip .conf files (they're service-specific profiles)
        [[ "$filename" == *.enabled ]] && continue  # Skip opt-in markers read by agent steps, not tuned
        cp "$file" "$TUNED_PROFILES_DIR/$final_profile_name/$filename"
        chmod +x "$TUNED_PROFILES_DIR/$final_profile_name/$filename" 2>/dev/null || true
        echo "Copied service file: $filename"
    done
}

# Write the active profile name for apply_tuned_profile.sh
write_tuned_profile() {
    local active_profile=$1
    echo "$active_profile" | tee "$CONFIGMAP_DIR/tuned_profile" > /dev/null
    echo "Set active tuned profile: $active_profile"
}

# Set reapply_sysctl = 0 in /etc/tuned/tuned-main.conf so tuned profile sysctl
# settings take precedence over /etc/sysctl.d (e.g. cloud_customizations.conf).
set_reapply_sysctl_off() {
    local tuned_main="/etc/tuned/tuned-main.conf"
    local before=""
    [[ -f "$tuned_main" ]] && before="$(cat "$tuned_main")"

    if [ -f "$tuned_main" ]; then
        if grep -qE '^[[:space:]]*reapply_sysctl[[:space:]]*=' "$tuned_main"; then
            # Match any value, not just "1": a line like "reapply_sysctl = 1 # note"
            # or "= 2" matches the grep but not the old sed, silently leaving it on.
            sed -i -E 's/^[[:space:]]*reapply_sysctl[[:space:]]*=.*$/reapply_sysctl = 0/' "$tuned_main"
            echo "Set reapply_sysctl = 0 in $tuned_main"
        else
            echo "reapply_sysctl = 0" >> "$tuned_main"
            echo "Added reapply_sysctl = 0 to $tuned_main"
        fi
    else
        echo "reapply_sysctl = 0" > "$tuned_main"
        echo "Created $tuned_main with reapply_sysctl = 0"
    fi

    # tuned reads tuned-main.conf only when the daemon starts (GlobalConfig.load_config
    # runs from __init__), and `tuned-adm profile` does not re-read it. install_tuned.sh
    # has already started tuned by this point, so without a restart the running daemon
    # keeps reapply_sysctl = 1 and re-applies /etc/sysctl.d over the profile's [sysctl]
    # values: tuned's _apply_sysctl_config_line logs "Overriding sysctl parameter" and
    # writes the /etc/sysctl.d value anyway rather than skipping options the profile owns.
    if [[ "$(cat "$tuned_main")" != "$before" ]] && systemctl is-active --quiet tuned; then
        echo "tuned-main.conf changed; restarting tuned so reapply_sysctl takes effect"
        systemctl restart tuned
    fi
}

main() {
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

    # Detect OS
    detect_os

    # Resolve the single profiles directory for the installed tuned version
    # and ensure it exists before deploying anything into it.
    resolve_tuned_profiles_dir
    mkdir -p "${TUNED_PROFILES_DIR}"

    # Deploy common base profiles
    deploy_common_profiles

    # Deploy ALL OS-specific profiles to /etc/tuned/
    deploy_os_profiles

    # When accelerator=generic, use nvidia-generic profile directly
    if [ "$ACCELERATOR" = "generic" ]; then
        PROFILE="nvidia-generic"
        echo "Accelerator is generic, using profile: $PROFILE"
        validate_profile "$PROFILE"
        write_tuned_profile "$PROFILE"
        set_reapply_sysctl_off
        echo "Profile preparation complete"
        return
    fi

    # Build profile name from components
    PROFILE=$(build_profile_name "$INTENT" "$ACCELERATOR")
    echo "Constructed profile: $PROFILE (intent=$INTENT, accelerator=$ACCELERATOR)"

    # Validate the constructed profile exists
    validate_profile "$PROFILE"

    # Check if service is specified (optional)
    if [ -f "$SERVICE_FILE" ]; then
        SERVICE=$(xargs < "$SERVICE_FILE")
    fi
    if [ -n "${SERVICE:-}" ]; then
        if [ "$SERVICE" = "common" ]; then
            echo "ERROR: 'common' is a reserved service name (used for shared helpers under profiles/service/common/)"
            exit 1
        fi
        echo "Requested service: $SERVICE"
        FINAL_PROFILE=$(build_final_profile_name "$SERVICE" "$ACCELERATOR" "$INTENT")
        echo "Final profile name: $FINAL_PROFILE (service=$SERVICE, accelerator=$ACCELERATOR, intent=$INTENT)"
        deploy_service_profile "$SERVICE" "$PROFILE" "$FINAL_PROFILE"
        write_tuned_profile "$FINAL_PROFILE"
    else
        # No service, use workload profile directly
        write_tuned_profile "$PROFILE"
    fi

    set_reapply_sysctl_off

    echo "Profile preparation complete"
}

main "$@"
