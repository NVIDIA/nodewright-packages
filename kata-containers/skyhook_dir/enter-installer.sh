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
    prepare|check-prepared|install|uninstall|smoke) ;;
    *) echo 'expected prepare, check-prepared, install, uninstall or smoke' >&2; exit 2 ;;
esac

# Called by run.sh after unshare: these mounts must never propagate to the host.
rootfs="${STEP_ROOT:?}/installer-rootfs"
# Make the chroot root a mount point for the installer's propagation check.
mount --bind "${rootfs}" "${rootfs}"
mount --rbind / "${rootfs}/root"
for directory in proc sys dev; do
    mount --rbind "/${directory}" "${rootfs}/${directory}"
done

# The existing adapter reads ConfigMaps through the host root mounted at /root.
export SKYHOOK_DIR="/root${SKYHOOK_DIR:?}"
exec chroot "${rootfs}" /bin/bash /usr/local/bin/nodewright-kata-stage "$@"
