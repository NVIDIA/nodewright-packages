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

remove_crashkernel_from_grub() {
    local kdump_grub_file="$1"
    if [[ -d /etc/default/grub.d ]]; then
        local grub_d_file="/etc/default/grub.d/${kdump_grub_file}"
        if [[ -f "$grub_d_file" ]]; then
            sed -i 's/\<crashkernel=[^" ]* *//g' "$grub_d_file"
        fi
    else
        local grub_file="/etc/default/grub"
        if [[ -f "$grub_file" ]]; then
            sed -i 's/\<crashkernel=[^" ]* *//g' "$grub_file"
        fi
    fi
}

update_grub_config() {
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        local grub_cfg="/boot/grub2/grub.cfg"
        [[ -d /sys/firmware/efi ]] && grub_cfg="/boot/efi/EFI/$(ls /boot/efi/EFI | head -n1)/grub.cfg"
        grub2-mkconfig -o "$grub_cfg"
    else
        echo "ERROR: could not detect grub update command."
        exit 1
    fi
}

remove_service() {
    systemctl stop "$1" || true
    systemctl disable "$1" || true
    systemctl status "$1" || true
}

source /etc/os-release
case $ID in
    ubuntu* | debian*)
        export DEBIAN_FRONTEND=noninteractive
        apt remove -o DPKG::Lock::Timeout=60 -y kdump-tools
        apt autoremove -y

        SERVICE_NAME="kdump-tools"
        GRUB_FILE="kdump-tools.cfg"
    ;;
    centos* | redhat* | amzn*)
        yum remove -y kexec-tools
        remove_service kdump

        SERVICE_NAME="kdump"
        GRUB_FILE="kdump.cfg"
    ;;
    fedora*)
        dnf remove -y kexec-tools
        remove_service kdump

        SERVICE_NAME="kdump"
        GRUB_FILE="kdump.cfg"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

remove_crashkernel_from_grub "$GRUB_FILE"
update_grub_config

remove_service "$SERVICE_NAME"
