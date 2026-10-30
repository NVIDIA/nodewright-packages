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
    tuned_version="$(get_tuned_version)"
    
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

# Get the installed tuned version string (e.g. "2.23.0").
# Echoes an empty string if tuned is not installed or the version cannot be parsed.
get_tuned_version() {
    tuned --version 2>/dev/null | awk '{print $2}'
}

# Set TUNED_PROFILES_DIR to the single directory all tuned profiles should be
# deployed to, based on the installed tuned version. tuned >= 2.23.0 reads
# profiles only from the profiles/ subdirectory (/etc/tuned/profiles); older
# tuned reads them directly from /etc/tuned. We deploy everything to this one
# user directory and write nothing to /usr/lib/tuned (tuned resolves include=
# targets across all profile_dirs, and the user dir takes precedence).
# Exits 1 if the tuned version cannot be determined.
resolve_tuned_profiles_dir() {
    local tuned_version major minor
    tuned_version="$(get_tuned_version)"
    if [ -z "$tuned_version" ]; then
        echo "ERROR: Could not determine tuned version"
        exit 1
    fi

    major="$(echo "$tuned_version" | cut -d. -f1)"
    minor="$(echo "$tuned_version" | cut -d. -f2)"

    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Could not parse tuned version: $tuned_version"
        exit 1
    fi

    if [[ "$major" -gt 2 ]] || { [[ "$major" -eq 2 ]] && [[ "$minor" -ge 23 ]]; }; then
        TUNED_PROFILES_DIR="/etc/tuned/profiles"
    else
        TUNED_PROFILES_DIR="/etc/tuned"
    fi

    echo "tuned $tuned_version: profiles dir is $TUNED_PROFILES_DIR"
}

# Return 0 if the named profile appears in `tuned-adm list` output read from
# stdin, non-zero otherwise. This is the pure, testable half of
# tuned_profile_exists.
#
# `tuned-adm list` pads the profile-name column to a fixed width and appends
# "- <summary>" for profiles that define one:
#
#   - nvidia-gb200-inference       - Optimized for inference workloads
#   - nvidia-gb200-multiNodeTraining- Optimized for multi-node distributed training
#
# Once a name is as long as the column, the padding space is dropped and the
# summary butts directly against the name (second line above). Anchoring the
# match to end-of-line (`^- <name>$`) therefore only matched summary-less
# profiles. Accept the name followed by whitespace (padded), the "- " summary
# separator (padding dropped), or end-of-line (no summary). Requiring a space
# after the separator dash keeps a name from matching a longer profile whose
# name merely starts with "<name>-" (e.g. nvidia-gb200 vs nvidia-gb200-inference).
#
# Usage: printf '%s\n' "$(tuned-adm list)" | tuned_list_has_profile <profile>
tuned_list_has_profile() {
    local profile="$1"
    grep -qE "^- ${profile}([[:space:]]|-[[:space:]]|$)"
}

# Return 0 if <profile> is a profile the installed tuned knows about.
# Usage: tuned_profile_exists <profile>
tuned_profile_exists() {
    tuned-adm list | tuned_list_has_profile "$1"
}

# How long, in total, one apt command waits on a lock another process holds:
# apt-daily or unattended-upgrades, or another NodeWright package on the node
# (nvidia-setup-kernel's apply runs alongside nvidia-tuned's). Whole seconds,
# 0 to 999999.
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"
# The pause between attempts when a run fails on a held lock. Whole seconds,
# 1 to 999999.
APT_LOCK_RETRY_INTERVAL_SECONDS="${APT_LOCK_RETRY_INTERVAL_SECONDS:-10}"

# Run an apt command, waiting up to APT_LOCK_WAIT_SECONDS in total for locks
# another process holds. nvidia-setup carries a copy (skyhook_dir/utilities.sh);
# the packages ship as separate images, so it is copied rather than shared.
# Two layers, because apt waits for only one lock itself:
#   1. apt waits for the dpkg frontend lock when DPkg::Lock::Timeout is set. It
#      is passed with -o, set to the time left in the budget. It has to be -o:
#      `apt`, unlike `apt-get`, carries its own 120s default
#      (Binary::apt::DPkg::Lock::Timeout), which outranks APT_CONFIG and the
#      apt.conf.d files. nvidia-setup's copy uses APT_CONFIG, which reaches the
#      apt-get and EFA installer runs it wraps.
#   2. Nothing waits for the lists lock `apt update` takes. A run that fails on
#      a held lock ("Could not get lock", "locked by another process") is
#      retried until the budget is spent; the last pause is cut short at the
#      deadline.
# stderr is captured to recognise a lock failure and replayed when the attempt
# ends; stdout still streams. apt runs with LC_ALL=C so its messages are the
# English ones matched here whatever the node's locale.
# Usage: apt_lock_retry apt|apt-get <args...>
apt_lock_retry() {
    local deadline remaining now pause status errfile

    if [[ ! "${APT_LOCK_WAIT_SECONDS}" =~ ^[0-9]{1,6}$ ]]; then
        echo "tuned: APT_LOCK_WAIT_SECONDS must be whole seconds from 0 to 999999, got '${APT_LOCK_WAIT_SECONDS}'" >&2
        return 2
    fi
    if [[ ! "${APT_LOCK_RETRY_INTERVAL_SECONDS}" =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "tuned: APT_LOCK_RETRY_INTERVAL_SECONDS must be whole seconds from 1 to 999999, got '${APT_LOCK_RETRY_INTERVAL_SECONDS}'" >&2
        return 2
    fi

    # 10# so a leading zero is not read as octal.
    deadline=$(( $(date +%s) + 10#${APT_LOCK_WAIT_SECONDS} ))
    errfile="$(mktemp)"
    while :; do
        remaining=$(( deadline - $(date +%s) ))
        [[ "${remaining}" -gt 0 ]] || remaining=1

        status=0
        LC_ALL=C "$1" -o "DPkg::Lock::Timeout=${remaining}" "${@:2}" 2> "${errfile}" || status=$?
        cat "${errfile}" >&2

        now="$(date +%s)"
        if [[ "${status}" -eq 0 ]] \
            || ! grep -qE 'Could not get lock|locked by another process' "${errfile}" \
            || [[ "${now}" -ge "${deadline}" ]]; then
            rm -f "${errfile}"
            return "${status}"
        fi
        pause="${APT_LOCK_RETRY_INTERVAL_SECONDS}"
        [[ $(( deadline - now )) -ge "${pause}" ]] || pause=$(( deadline - now ))
        echo "tuned: '$*' found an apt or dpkg lock held by another process; retrying in ${pause}s" >&2
        sleep "${pause}"
    done
}
