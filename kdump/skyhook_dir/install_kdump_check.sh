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

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command '$1' not found. installation failed."
        exit 1
    fi
}

check_service() {
    if ! systemctl is-active --quiet "$1"; then
        echo "ERROR: Service '$1' is NOT running."
        exit 1
    fi
}

source /etc/os-release
case $ID in
    ubuntu* | debian*)
        SERVICE_NAME="kdump-tools"
    ;;
    centos* | redhat* | amzn* | fedora*)
        SERVICE_NAME="kdump"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

check_command kexec
check_service "$SERVICE_NAME"
