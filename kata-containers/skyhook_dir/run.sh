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

case "${1:-}" in
    validate|prepare|check-prepared|install|uninstall|check-installed|check-removed|finalize|check-finalized) action="$1" ;;
    *) echo "usage: $0 {validate|prepare|check-prepared|install|uninstall|check-installed|check-removed|finalize|check-finalized}" >&2; exit 2 ;;
esac

source "${STEP_ROOT:?}/distribution.sh"
kata_resolve_distribution

# Query the distribution's running server, not an unrelated system containerd.
if [[ -z ${CONTAINER_RUNTIME_VERSION:-} ]]; then
    if [[ "$action" == uninstall || "$action" == check-removed ]] &&
        [[ -n ${KATA_SAVED_RUNTIME_VERSION:-} ]]; then
        export CONTAINER_RUNTIME_VERSION="$KATA_SAVED_RUNTIME_VERSION"
    else
        CONTAINER_RUNTIME_VERSION="$(kata_detect_containerd_version)"
        export CONTAINER_RUNTIME_VERSION
    fi
fi

bash "${STEP_ROOT:?}/run-inner.sh" validate
# EROFS memory mode with dm-verity needs the configuration added in 2.3.
# Keep cleanup available for an earlier, incompatible installation.
case "$action" in
    uninstall|check-removed) ;;
    *)
        [[ "$CONTAINER_RUNTIME_VERSION" =~ ^containerd://([0-9]+)\.([0-9]+)\. ]]
        if (( 10#${BASH_REMATCH[1]} < 2 ||
              (10#${BASH_REMATCH[1]} == 2 && 10#${BASH_REMATCH[2]} < 3) )); then
            echo 'this EROFS memory/dm-verity profile requires containerd >= 2.3' >&2
            exit 1
        fi
        ;;
esac
case "${action}" in
    validate) exit 0 ;;
    check-installed|finalize|check-finalized)
        test -x /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
        test -s /opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-nvidia-cpu-runtime-rs.toml
        if [[ "$action" == finalize ]]; then
            if [[ ! -e "${STEP_ROOT:?}/installer-rootfs" && -f "${STEP_ROOT}/smoke-tested" ]] &&
                grep -Fxq -- "$NODE_NAME" "${STEP_ROOT}/smoke-tested"; then
                exit 0
            fi
            test -x "${STEP_ROOT}/installer-rootfs/usr/bin/kata-deploy"
            rm -f -- "${STEP_ROOT}/smoke-tested"
            unshare --mount --propagation private "${STEP_ROOT}/enter-installer.sh" smoke
            (umask 077; printf '%s\n' "$NODE_NAME" > "${STEP_ROOT}/smoke-tested.tmp")
            mv "${STEP_ROOT}/smoke-tested.tmp" "${STEP_ROOT}/smoke-tested"
            rm -rf -- "${STEP_ROOT:?}/installer-rootfs"
        elif [[ "$action" == check-finalized ]]; then
            test -f "${STEP_ROOT:?}/smoke-tested"
            grep -Fxq -- "$NODE_NAME" "${STEP_ROOT}/smoke-tested"
            test ! -e "${STEP_ROOT:?}/installer-rootfs"
        fi
        exit 0
        ;;
    check-removed)
        test ! -e /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
        test ! -e "${STEP_ROOT:?}/installer-rootfs"
        test ! -e "${STEP_ROOT}/smoke-tested"
        exit 0
        ;;
esac

if [[ ! -x "${STEP_ROOT}/installer-rootfs/usr/bin/kata-deploy" ]]; then
    echo 'bundled Kata installer filesystem is missing or incomplete' >&2
    exit 1
fi
# Keep the same distro and paths when uninstall runs with an inactive service.
kata_save_distribution
# Wait for the private namespace to exit before deleting its backing files.
unshare --mount --propagation private "${STEP_ROOT}/enter-installer.sh" "${action}"
if [[ "$action" == uninstall ]]; then
    rm -f -- "${STEP_ROOT}/smoke-tested"
    rm -rf -- "${STEP_ROOT:?}/installer-rootfs"
fi
