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

source /etc/os-release
case $ID in
    ubuntu* | debian*)
        export DEBIAN_FRONTEND=noninteractive

        # Refresh the package indexes. A single unreachable or stale third-party
        # repo makes `apt update` exit 100, which under `set -e` fails the whole
        # package even when every index we actually need refreshed fine.
        # Tolerating that is safe because the `apt install` below is
        # unconditional and still fails loudly if tuned is genuinely
        # unavailable. Set APT_ALLOW_INDEX_FAILURE=false on the Skyhook custom
        # resource's package env to restore strict behavior.
        if [ "${APT_ALLOW_INDEX_FAILURE:-true}" = "true" ]; then
            apt update -y || echo "WARN: apt update reported errors; continuing (APT_ALLOW_INDEX_FAILURE=true)" >&2
        else
            apt update -y
        fi
        apt install -o DPKG::Lock::Timeout=60 -y tuned
    ;;
    centos* | redhat* | amzn*)
        yum update -y
        yum install -y tuned
    ;;
    fedora*)
        dnf upgrade -y
        dnf install -y tuned
    ;;
    *)
        echo "Unsupported Distro: $ID"
        exit 1
    ;;
esac

# enable tuned service
systemctl enable --now tuned
systemctl status tuned
