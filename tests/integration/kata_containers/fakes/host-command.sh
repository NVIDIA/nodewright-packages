#!/usr/bin/env bash
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

set -euo pipefail
command="${0##*/}"
if [[ "${command}" == uname ]]; then printf '%s\n' "${TEST_ARCH}"; exit 0; fi
if [[ "${command}" == systemctl ]]; then
    unit="${!#}"
    [[ " ${TEST_SYSTEMD_UNITS:-} " == *" ${unit%.service} "* ]]
    exit $?
fi
if [[ "${command}" == ctr || "${command}" == k3s || "${command}" == k0s || "${command}" == microk8s ]]; then
    printf '%s %s\n' "${command}" "$*" >> "${TRACE}"
    if [[ ${TEST_CLIENT_TRACE:-} == 1 ]]; then printf '%s' "$0" > /tmp/kata-client; fi
    if [[ ${FAIL_COMMAND:-} == ctr ]]; then exit 7; fi
    printf 'Client:\n  Version: v1.7.0\n\nServer:\n  Version: %s\n' "${TEST_CONTAINERD_VERSION-v2.4.2}"
    # Catch parsers that close the pipe early while ctr is still writing.
    printf '%131072s\n' ''
    exit 0
fi
if [[ "${command}" == unshare ]]; then
    if [[ ${TEST_PROFILE:-} == 1 ]]; then
        printf '%s' "${CONTAINER_RUNTIME_VERSION}|${K8S_DISTRIBUTION}|${KATA_HOST_CONTAINERD_CONFIG_DIR}|${KATA_CONTAINERD_SOCKET}" > "${ENV_TRACE}"
    else
        printf '%s' "${CONTAINER_RUNTIME_VERSION}" > "${ENV_TRACE}"
    fi
fi
if [[ "${command}" == kata-deploy ]]; then
    if [[ ${TEST_PROFILE:-} == 1 ]]; then
        printf '%s' "${CONTAINER_RUNTIME_VERSION}|${K8S_DISTRIBUTION}|${KATA_HOST_CONTAINERD_CONFIG_DIR}|${KATA_CONTAINERD_SOCKET}" > "${ENV_TRACE}"
    else
        printf '%s\n' "${SHIMS_AARCH64}|${EXPERIMENTAL_SETUP_SNAPSHOTTER}|${SNAPSHOTTER_HANDLER_MAPPING_AARCH64}|${CONTAINERD_CONFIG_FILE_NAME}" > "${ENV_TRACE}"
    fi
fi
{
    printf '%s' "${command}"
    printf ' %s' "$@"
    printf '\n'
} >> "${TRACE}"
if [[ "${command} $*" == "${FAIL_COMMAND:-}" ]]; then exit 7; fi
