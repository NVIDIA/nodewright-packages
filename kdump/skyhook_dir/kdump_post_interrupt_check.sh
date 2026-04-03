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

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"

CRASHKERNEL_VALUE=""
CRASHKERNEL_FILE="${CONFIGMAP_DIR}/crashkernel"
if [[ -f "$CRASHKERNEL_FILE" ]]; then
    CRASHKERNEL_VALUE=$(<"$CRASHKERNEL_FILE")
fi

check_grub_configuration() {
    if [[ -z "$CRASHKERNEL_VALUE" ]]; then
        echo "WARNING: crashkernel value is empty — skipping crashkernel check."
        return
    fi

    local grub_file="$1"

    local grub_d_file="/etc/default/grub.d/${grub_file}"
    local main_grub="/etc/default/grub"
    local found=false

    if [[ -f "$grub_d_file" ]]; then
        if grep -qE "crashkernel=${CRASHKERNEL_VALUE}" "$grub_d_file"; then
            found=true
        else
            echo "ERROR: crashkernel not found or incorrect in ${grub_d_file}"
            exit 1
        fi
    fi

    if [[ "$found" == false && -f "$main_grub" ]]; then
        if grep -qE "crashkernel=${CRASHKERNEL_VALUE}" "$main_grub"; then
            found=true
        else
            echo "ERROR: crashkernel not found or incorrect in ${main_grub}"
            exit 1
        fi
    fi

    if [[ "$found" == false ]]; then
        echo "ERROR: grub configuration file not found: ${grub_d_file} or ${main_grub}"
        exit 1
    fi
}

check_active_kernel() {
    if [[ ! -f /proc/cmdline ]]; then
        echo "ERROR: cannot read /proc/cmdline"
        exit 1
    fi

    if [[ -z "$CRASHKERNEL_VALUE" ]]; then
        if ! grep -qE "crashkernel=" /proc/cmdline; then
            echo "ERROR: crashkernel not active in running kernel"
            exit 1
        fi
    else
        if ! grep -qE "crashkernel=${CRASHKERNEL_VALUE}" /proc/cmdline; then
            echo "ERROR: crashkernel not active in running kernel"
            exit 1
        fi
    fi
}

check_kdump_config_file() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: kdump configuration file not found: ${config_file}"
        exit 1
    fi
}

check_service() {
    if ! systemctl is-active --quiet "$1"; then
        echo "Error: Service '$1' is NOT running."
        exit 1
    fi
}

# determine distro-specific settings
source /etc/os-release
case $ID in
    ubuntu*|debian*)
        CONFIG_FILE="/etc/default/kdump-tools"
        GRUB_FILE="kdump-tools.cfg"
        SERVICE_NAME="kdump-tools"
    ;;
    centos*|rhel*|amzn*|fedora*)
        CONFIG_FILE="/etc/kdump.conf"
        GRUB_FILE="kdump.cfg"
        SERVICE_NAME="kdump"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

check_grub_configuration "$GRUB_FILE"
check_kdump_config_file "$CONFIG_FILE"

check_service "$SERVICE_NAME"
check_active_kernel
