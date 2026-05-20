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


set -e


if [ ${SET_X:-0} -eq 1 ]; then
    set -x
fi

# SKYHOOK_RESOURCE_ID is {id}_{package name}_{version}
# We want to use the package name in the drop in files so multiple tuning packages can be installed
package_name=$(echo ${SKYHOOK_RESOURCE_ID} | cut -f 2 -d _)

if [ -f /etc/sysctl.d/999-${package_name}-tuning.conf ]; then
    rm /etc/sysctl.d/999-${package_name}-tuning.conf
fi

if [ -f /etc/security/limits.d/999-${package_name}-tuning.conf ]; then
    rm /etc/security/limits.d/999-${package_name}-tuning.conf
fi

# remove any service drop in files that may have been created
# Use -f so a literal/unmatched glob (no .d/ directories or no matching file)
# does not trip `set -e` during uninstall on a clean node.
rm -f /etc/systemd/system/*.d/999-${package_name}-tuning.conf

if [ -f /etc/default/grub.d/999-${package_name}-tuning.cfg ]; then
    rm /etc/default/grub.d/999-${package_name}-tuning.cfg
fi
