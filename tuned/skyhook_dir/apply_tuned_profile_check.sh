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


set -x

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
# Verify custom profiles where the installed tuned version reads them.
resolve_tuned_profiles_dir
TUNED_DIR="${TUNED_PROFILES_DIR}"
SCRIPTS_DIR="/etc/tuned/scripts"

# check tuned service is installed and running
if ! command -v tuned-adm >/dev/null 2>&1; then
    echo "ERROR: tuned-adm is not installed"
    exit 1
fi

if ! systemctl is-active --quiet tuned; then
    echo "ERROR: tuned service is not running"
    exit 1
fi

# check configmaps directory exists
if [ ! -d "$CONFIGMAP_DIR" ]; then
    echo "ERROR: configmaps directory does not exist: $CONFIGMAP_DIR"
    exit 1
fi

if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "ERROR: scripts directory does not exist: $SCRIPTS_DIR"
    exit 1
fi

# verify deployed scripts
for file in "$CONFIGMAP_DIR"/*_script; do
    [ -f "$file" ] || continue
    
    script_name=$(basename "$file")
    script_path="$SCRIPTS_DIR/${script_name#*_script}"
    
    # If the script name is just "_script", use the full filename
    if [ "${script_name#*_script}" = "" ]; then
        script_path="$SCRIPTS_DIR/$(basename "$file")"
    fi
    
    if [ ! -f "$script_path" ]; then
        echo "ERROR: deployed script missing: $script_path"
        exit 1
    fi
    
    if [ ! -x "$script_path" ]; then
        echo "ERROR: deployed script not executable: $script_path"
        exit 1
    fi
    
    echo "verified deployed script: $script_name -> $script_path"
done

# verify custom profiles (skip tuned_profile and *_script files)
for file in "$CONFIGMAP_DIR"/*; do
    [ -f "$file" ] || continue

    base_file=$(basename "$file")
    [ "$base_file" = "tuned_profile" ] && continue
    [[ "$base_file" == *"_script" ]] && continue    # skip script files

    custom_profile_dir="$TUNED_DIR/$base_file"
    custom_profile_file="$custom_profile_dir/tuned.conf"

    if [ ! -d "$custom_profile_dir" ]; then
        echo "ERROR: custom tuned profile directory missing: $custom_profile_dir"
        exit 1
    fi

    if [ ! -f "$custom_profile_file" ]; then
        echo "ERROR: tuned configuration file missing: $custom_profile_file"
        exit 1
    fi

    echo "verified custom profile: $base_file"
done

# verify the main profile(s) are active
# Supports multiple space-separated profiles, e.g., "hpc-compute aws"
TUNED_PROFILE_FILE="$CONFIGMAP_DIR/tuned_profile"
if [ ! -f "$TUNED_PROFILE_FILE" ]; then
    echo "WARNING: tuned_profile file missing in $CONFIGMAP_DIR"
else
    tuned_profiles=$(xargs < "$TUNED_PROFILE_FILE")
    
    # Count the number of profiles
    # shellcheck disable=SC2086
    profile_count=$(echo $tuned_profiles | wc -w)
    
    # Check tuned version if multiple profiles are specified
    check_tuned_version_for_multiple_profiles "$profile_count"
    
    # Validate each profile exists
    available_profiles=$(tuned-adm list)
    for profile in $tuned_profiles; do
        if ! echo "$available_profiles" | grep -q "^- $profile$"; then
            echo "ERROR: tuned profile '$profile' not found in tuned-adm list"
            exit 1
        fi
    done
    
    # Check active profiles match expected profiles
    active_profile=$(tuned-adm active | awk -F: '{print $2}' | xargs)
    if [ "$active_profile" != "$tuned_profiles" ]; then
        echo "ERROR: tuned profile(s) '$tuned_profiles' not active (active: $active_profile)"
        exit 1
    fi
fi

# verify that the profile is applied
if ! tuned-adm verify; then
    echo "ERROR: tuned-adm verify failed"

    echo "tuned-adm verify logs:"
    cat /var/log/tuned/tuned.log

    if [[ "${INTERRUPT}" != "true" ]]; then
        echo "WARNING: Set the INTERRUPT environment variable to true if you're tunings require an interrupt or else the tunings can't be verified"
        exit 1
    fi
fi
