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

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"

CRASHKERNEL_VALUE=""
CRASHKERNEL_FILE="${CONFIGMAP_DIR}/crashkernel"
if [[ -f "$CRASHKERNEL_FILE" ]]; then
    CRASHKERNEL_VALUE=$(<"$CRASHKERNEL_FILE")
fi

configure_grub() {
    local kdump_grub_file="$1"

    if [[ -z "$CRASHKERNEL_VALUE" ]]; then
        echo "WARNING: crashkernel value is empty — using default crashkernel value."
        return
    fi

    if [[ -d /etc/default/grub.d ]]; then
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=${CRASHKERNEL_VALUE}\"" > "/etc/default/grub.d/${kdump_grub_file}"
    else
        local grub_file="/etc/default/grub"
        if grep -q "crashkernel=" "$grub_file"; then
            sed -i "s/crashkernel=[^ \"']*/crashkernel=${CRASHKERNEL_VALUE}/" "$grub_file"
        else
            sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"crashkernel=${CRASHKERNEL_VALUE} /" "$grub_file"
        fi
    fi
}

update_grub_config() {
    if [[ -z "$CRASHKERNEL_VALUE" ]]; then
        echo "WARNING: crashkernel value is empty — skipping grub update."
        return
    fi

    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        local grub_cfg="/boot/grub2/grub.cfg"
        if [[ -d /sys/firmware/efi ]]; then
            local efi_dir="/boot/efi/EFI"
            local distro_dir
            distro_dir=$(ls "$efi_dir" | head -n1)
            grub_cfg="${efi_dir}/${distro_dir}/grub.cfg"
        fi
        grub2-mkconfig -o "$grub_cfg"
    else
        echo "ERROR: could not detect grub update command."
        exit 1
    fi
}

copy_kdump_config() {
    local config_file="$1"
    local source_config="${CONFIGMAP_DIR}/kdump.conf"

    if [[ -f "$source_config" ]]; then
        cp "$source_config" "$config_file"
    else
        echo "WARNING: ${source_config} not found — using current or default configuration"
    fi
}

# determine distro-specific settings
source /etc/os-release
case $ID in
    ubuntu*|debian*)
        CONFIG_FILE="/etc/default/kdump-tools"
        GRUB_FILE="kdump-tools.cfg"
    ;;
    centos*|redhat*|amzn*|fedora*)
        CONFIG_FILE="/etc/kdump.conf"
        GRUB_FILE="kdump.cfg"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

# execute configuration steps
configure_grub "$GRUB_FILE"
update_grub_config
copy_kdump_config "$CONFIG_FILE"
