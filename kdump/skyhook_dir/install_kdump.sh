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

start_service() {
    systemctl enable --now "$1"
    systemctl status "$1"
}

source /etc/os-release
case $ID in
    ubuntu* | debian*)
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -o DPKG::Lock::Timeout=60 -y kdump-tools

        SERVICE_NAME="kdump-tools"
    ;;
    centos* | redhat* | amzn*)
        yum update -y
        yum install -y kexec-tools

        SERVICE_NAME="kdump"
    ;;
    fedora*)
        dnf update -y
        dnf install -y kexec-tools

        SERVICE_NAME="kdump"
    ;;
    *)
        echo "ERROR: unsupported distro: $ID"
        exit 1
    ;;
esac

start_service "$SERVICE_NAME"
