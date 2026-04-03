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


if [ ${SET_X:-0} -eq 1 ]; then
set -x
fi

failures=""

if [ -f ${SKYHOOK_DIR}/configmaps/sysctl.conf ]; then
    echo "-------------------------"
    echo "Checking sysctl settings"
    echo "-------------------------"
    while IFS= read -r line
    do
        name=$(echo $line | cut -f 1 -d =)
        exp_value=$(echo $line | cut -f 2 -d =)
        value=$(sysctl $name | cut -f 2 -d =)
        if [ $exp_value != $value ]; then
            failures=$(printf "%s\n%s" "${failures}" "$name:  ${exp_value} != ${value}")
        fi
    done  <<< $(cat ${SKYHOOK_DIR}/configmaps/sysctl.conf)
fi

function container_check {
    file=$1
    echo "-------------------------"
    echo "Check container limits"
    echo "-------------------------"
    while IFS= read -r line
    do
        name=$(echo $line | cut -f 1 -d = | sed 's/Limit//g')
        expected_value=$(echo $line | cut -f 2 -d =)
        if [ ${expected_value} == "infinity" ]; then
            continue
        fi
        case $name in
            "NOFILE")
                actual_value=$(ulimit -n)
            ;;
            "FSIZE")
                actual_value=$(ulimit -f)
            ;;
            "STACK")
                actual_value=$(ulimit -s)
                # The value is actually 1024 of the expected value due to being in KB
                expected_value=$((${expected_value} / 1024))
            ;;
            "NPROC")
                actual_value=$(ulimit -u)
            ;;
            "MEMLOCK")
                actual_value=$(ulimit -l)
                # The value is actually 1024 of the expected value due to being in KB
                if [ ${expected_value} != "infinity" ]; then
                    expected_value="infinity"
                else
                    expected_value=$((${expected_value} / 1024))
                fi
            ;;
            *)
            echo "Unkown setting ${name}"
            ;;
        esac
        if [ ${expected_value} != ${actual_value} ]; then
            failures=$(printf "%s\n%s" "${failures}" "$name: ${expected_value} != ${actual_value}")
        fi
    # Use cat here instead of < file in case of single line files
    done <<< $(cat $file | grep Limit)
}

if [ -f ${SKYHOOK_DIR}/configmaps/service_containerd.conf ]; then
    container_check ${SKYHOOK_DIR}/configmaps/service_containerd.conf
fi

if [ -f ${SKYHOOK_DIR}/configmaps/service_crio.conf ]; then
    container_check ${SKYHOOK_DIR}/configmaps/service_crio.conf
fi

if [ -f ${SKYHOOK_DIR}/configmaps/grub.conf ]; then
    echo "-------------------------"
    echo "Checking grub settings"
    echo "-------------------------"
    grub_update=""
    while IFS= read -r line
    do
        grub_update="${grub_update} ${line}"
    done <<< $(cat ${SKYHOOK_DIR}/configmaps/grub.conf)
    if [ $(grep -c "${grub_update}" /proc/cmdline) -eq 0 ]; then
        failures=$(printf "%s\n%s" "${failures}" "${grub_update} NOT in kernel cmdline: $(cat /proc/cmdline)")
    fi
fi

if [ -n "$failures" ]; then
    echo "${failures}"
    exit 1
fi
