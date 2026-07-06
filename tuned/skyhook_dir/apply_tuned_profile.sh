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


set -xe
set -u

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
# Deploy custom profiles where the installed tuned version reads them.
resolve_tuned_profiles_dir
TUNED_DIR="${TUNED_PROFILES_DIR}"
SCRIPTS_DIR="/etc/tuned/scripts"

# ensure tuned directory exists
mkdir -p "$TUNED_DIR"
mkdir -p "$SCRIPTS_DIR"

# First, deploy all scripts ending with "_script" to the shared scripts directory
echo "Deploying scripts to $SCRIPTS_DIR..."
for file in "$CONFIGMAP_DIR"/*_script; do
    [ -f "$file" ] || continue # make sure file exists
    
    script_name=$(basename "$file")
    script_path="$SCRIPTS_DIR/${script_name#*_script}"
    
    # If the script name is just "_script", use the full filename
    if [ "${script_name#*_script}" = "" ]; then
        script_path="$SCRIPTS_DIR/$(basename "$file")"
    fi
    
    # Copy the script and make it executable
    cp "$file" "$script_path"
    chmod +x "$script_path"
    echo "deployed script: $script_name -> $script_path"
done

# process all other files as custom profiles (skip tuned_profile and *_script files)
for file in "$CONFIGMAP_DIR"/*; do
    [ -f "$file" ] || continue # make sure file exists

    profile_name=$(basename "$file")
    [ "$profile_name" = "tuned_profile" ] && continue  # skip tuned_profile
    [[ "$profile_name" == *"_script" ]] && continue    # skip script files
    
    custom_profile_dir="$TUNED_DIR/$profile_name"

    # Create a directory for the custom profile if it doesn't exist
    mkdir -p "$custom_profile_dir"

    # Copy the file contents as tuned.conf
    cp "$file" "$custom_profile_dir/tuned.conf"
    echo "created custom tuned profile: $profile_name"
done

# Now apply the main profile(s)
# Supports multiple space-separated profiles, e.g., "hpc-compute aws"
TUNED_PROFILE_FILE="$CONFIGMAP_DIR/tuned_profile"
if [ -f "$TUNED_PROFILE_FILE" ]; then
    tuned_profiles=$(cat "$TUNED_PROFILE_FILE" | xargs)  # read and trim
    
    # Count the number of profiles
    # shellcheck disable=SC2086
    profile_count=$(echo $tuned_profiles | wc -w)
    
    # Check tuned version if multiple profiles are specified
    check_tuned_version_for_multiple_profiles "$profile_count"
    
    # Validate each profile exists before applying
    available_profiles=$(tuned-adm list)
    for profile in $tuned_profiles; do
        if ! echo "$available_profiles" | grep -q "^- $profile$"; then
            echo "ERROR: tuned profile '$profile' not found"
            exit 1
        fi
    done
    
    echo "applying tuned profile(s): $tuned_profiles"
    # shellcheck disable=SC2086
    tuned-adm profile $tuned_profiles
else
    echo "WARNING: no tuned_profile file found in $CONFIGMAP_DIR"
fi
