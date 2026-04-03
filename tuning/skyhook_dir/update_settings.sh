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

if [ -f ${SKYHOOK_DIR}/configmaps/sysctl.conf ]; then
    echo "-------------------------"
    echo "Updating sysctl settings"
    echo "-------------------------"
    sysctl -p ${SKYHOOK_DIR}/configmaps/sysctl.conf
    # Permenant setting
    cp ${SKYHOOK_DIR}/configmaps/sysctl.conf /etc/sysctl.d/999-${package_name}-tuning.conf
    # Must use RestartAllService interrupt OR reboot to apply changes
fi

if [ -f ${SKYHOOK_DIR}/configmaps/ulimit.conf ]; then
    echo "-------------------------"
    echo "Updating ulimit settings"
    echo "-------------------------"
    temp_file=$(mktemp)
    while IFS= read -r line
    do
        name=$(echo $line | cut -f 1 -d =)
        value=$(echo $line | cut -f 2 -d =)
        # Set for this boot
        case $name in
            "memlock")
                ulimit -l $value
            ;;
            "nofile")
                ulimit -n $value
            ;;
            "fsize")
                ulimit -f ${value}
            ;;
            "stack")
                ulimit -s ${value}
            ;;
            "nproc")
                ulimit -u ${value}
            ;;
            *)
            echo "Unkown setting ${name}"
            continue
            ;;
        esac
        # Set permenantly by writing to a drop in file. Use a -temp one in case it already exists
        # then we can move it over if everything is successful
        echo "* hard ${name} ${value}" >> ${temp_file}
    done  <<< $(cat ${SKYHOOK_DIR}/configmaps/ulimit.conf)
    # Move the temp file over to the final location
    mv ${temp_file} /etc/security/limits.d/999-${package_name}-tuning.conf
    chmod a+r /etc/security/limits.d/999-${package_name}-tuning.conf
    

    # Update session files so on reboot limits file is correclty applied
    for f in /etc/pam.d/common-session*; do
        if [ $(grep -c "session required pam_limits.so" $f) -eq 0 ]; then
            echo "session required pam_limits.so" >> $f
        fi
    done
fi

if [ $(ls ${SKYHOOK_DIR}/configmaps | grep -c service_.*.conf) -gt 0 ]; then
    # Loop through all service files and add them as drop-ins
    for f in ${SKYHOOK_DIR}/configmaps/service_*.conf; do
        service_name=$(basename ${f} | cut -f 2 -d _ | cut -f 1 -d .)
        echo "-------------------------"
        echo "Updating ${service_name} settings"
        echo "-------------------------"
        mkdir -p /etc/systemd/system/${service_name}.service.d
        cp ${f} /etc/systemd/system/${service_name}.service.d/999-${package_name}-tuning.conf
    done


    echo "-------------------------"
    echo "Reloading systemd"
    echo "-------------------------"
    systemctl daemon-reload
fi

if [ -f ${SKYHOOK_DIR}/configmaps/grub.conf ]; then
    echo "-------------------------"
    echo "Updating grub settings"
    echo "-------------------------"
    grub_update=""
    while IFS= read -r line
    do
        grub_update="${grub_update} ${line}"
    done <<< $(cat ${SKYHOOK_DIR}/configmaps/grub.conf)
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\" ${grub_update}\"" > /etc/default/grub.d/999-${package_name}-tuning.cfg
    update-grub
fi
