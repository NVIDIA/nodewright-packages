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


set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

source /etc/os-release
case "${ID}" in
    ubuntu* | debian*)
        export DEBIAN_FRONTEND=noninteractive

        apt_lock_retry apt remove -y tuned && apt_lock_retry apt autoremove -y
    ;;
    centos* | redhat* | amzn*)
        yum remove -y tuned
    ;;
    fedora*)
        dnf remove -y tuned
    ;;
    opensuse-microos | opensuse-leap-micro)
        echo "Unsupported Distro: ${ID} (read-only root, use transactional-update)"
        exit 1
    ;;
    sles* | opensuse*)
        # zypper exits 104 when tuned is not installed. Skip it in that case so
        # uninstall is a no-op on re-run, matching the apt branch. As in
        # install_tuned.sh, accept the informational exit codes 106 (repo
        # skipped) and 107 (RPM scriptlet failed) only when rpm confirms tuned
        # is gone, so the service cleanup below still runs.
        if rpm -q tuned >/dev/null 2>&1; then
            rc=0
            ZYPP_LOCK_TIMEOUT=60 zypper --non-interactive remove tuned || rc=$?
            if [[ "${rc}" -ne 0 ]]; then
                if [[ "${rc}" -eq 106 || "${rc}" -eq 107 ]] && ! rpm -q tuned >/dev/null 2>&1; then
                    echo "WARN: zypper exited ${rc} but tuned is removed; continuing" >&2
                else
                    exit "${rc}"
                fi
            fi
        fi
    ;;
    *)
        echo "Unsupported Distro: ${ID}"
        exit 1
    ;;
esac

# disable and stop tuned service
if systemctl is-active --quiet tuned; then
    systemctl disable --now tuned
    # Informational only: `systemctl status` exits 3 for a stopped unit.
    systemctl status tuned || true
fi
