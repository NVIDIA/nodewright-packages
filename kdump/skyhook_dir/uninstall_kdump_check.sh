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

check_removed_command() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: command '$1' not removed."
        exit 1
    fi
}

check_removed_service() {
    if systemctl is-active --quiet "$1"; then
        echo "ERROR: service '$1' is STILL running."
        exit 1
    fi
}

check_removed_crashkernel() {
    local grub_file="$1"

    local grub_d_file="/etc/default/grub.d/${grub_file}"
    local main_grub="/etc/default/grub"
    local crashkernel_found=false

    if [[ -f "$grub_d_file" ]]; then
        if grep -qE '\bcrashkernel=' "$grub_d_file"; then
            echo "ERROR: crashkernel parameter still present in ${grub_d_file}"
            crashkernel_found=true
        fi
    fi

    if [[ -f "$main_grub" ]]; then
        if grep -qE '\bcrashkernel=' "$main_grub"; then
            echo "ERROR: crashkernel parameter still present in ${main_grub}"
            crashkernel_found=true
        fi
    fi

    if [[ "$crashkernel_found" == true ]]; then
        exit 1
    fi
}

source /etc/os-release
case $ID in
    ubuntu* | debian*)
        SERVICE_NAME="kdump-tools"
        GRUB_FILE="kdump-tools.cfg"
    ;;
    centos* | redhat* | amzn* | fedora*)
        SERVICE_NAME="kdump"
        GRUB_FILE="kdump.cfg"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

check_removed_crashkernel "$GRUB_FILE"
check_removed_service "$SERVICE_NAME"
check_removed_command kexec

echo "WARNING: the crashkernel parameter has been removed from the GRUB configuration, but requires a reboot to take effect"
