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


# Shared utility functions for tuned scripts

# Function to check if tuned version supports multiple profiles (requires >= 2.24)
# Usage: check_tuned_version_for_multiple_profiles <profile_count>
# Returns: 0 if OK, exits with 1 if version check fails
check_tuned_version_for_multiple_profiles() {
    local profile_count=$1
    
    # Only check if multiple profiles are specified
    if [ "$profile_count" -le 1 ]; then
        return 0
    fi
    
    # Get tuned version (format: "tuned 2.21.0")
    local tuned_version
    tuned_version=$(tuned --version 2>/dev/null | awk '{print $2}')
    
    if [ -z "$tuned_version" ]; then
        echo "ERROR: Could not determine tuned version"
        exit 1
    fi
    
    # Extract major.minor version (e.g., "2.21" from "2.21.0")
    local major minor
    major=$(echo "$tuned_version" | cut -d. -f1)
    minor=$(echo "$tuned_version" | cut -d. -f2)
    
    # Check if version >= 2.24
    # Version comparison: 2.24+ supports multiple profiles
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 24 ]; }; then
        echo "ERROR: Multiple tuned profiles require tuned version >= 2.24"
        echo "       Current version: $tuned_version"
        echo "       Profiles specified: $profile_count"
        echo ""
        echo "Workarounds:"
        echo "  1. Use a single profile with 'include=' directive to inherit from other profiles"
        echo "  2. Upgrade tuned to version 2.24 or later"
        echo "  3. Use Ubuntu 25.04+ or a distribution with tuned >= 2.24"
        exit 1
    fi
    
    echo "tuned version $tuned_version supports multiple profiles"
}
