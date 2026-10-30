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

        # Refresh the package indexes. A single unreachable or stale third-party
        # repo makes `apt update` exit 100, which under `set -e` fails the whole
        # package even when every index we actually need refreshed fine.
        # Tolerating that is safe because the `apt install` below is
        # unconditional and still fails loudly if tuned is genuinely
        # unavailable. Set APT_ALLOW_INDEX_FAILURE=false on the Skyhook custom
        # resource's package env to restore strict behavior. A lock another
        # process holds is waited out first (apt_lock_retry), so it is not
        # mistaken for an index failure.
        if [[ "${APT_ALLOW_INDEX_FAILURE:-true}" == "true" ]]; then
            apt_lock_retry apt update -y || echo "WARN: apt update reported errors; continuing (APT_ALLOW_INDEX_FAILURE=true)" >&2
        else
            apt_lock_retry apt update -y
        fi
        apt_lock_retry apt install -y tuned
    ;;
    centos* | redhat* | amzn*)
        yum update -y
        yum install -y tuned
    ;;
    fedora*)
        dnf upgrade -y
        dnf install -y tuned
    ;;
    opensuse-microos | opensuse-leap-micro)
        # Transactional systems: the root filesystem is read-only, so a plain
        # `zypper install` fails. tuned has to be added with transactional-update.
        echo "Unsupported Distro: ${ID} (read-only root, use transactional-update)"
        exit 1
    ;;
    sles* | opensuse*)
        # zypper reports two outcomes that leave tuned installed with non-zero
        # informational exit codes: 106 when a repo could not be refreshed and
        # was skipped, and 107 when an RPM scriptlet failed. Accept those only
        # when rpm confirms tuned is installed; any other failure still fails
        # the step. ZYPP_LOCK_TIMEOUT waits for a held zypp lock instead of
        # exiting 7 immediately, like DPKG::Lock::Timeout in the apt branch.
        rc=0
        ZYPP_LOCK_TIMEOUT=60 zypper --non-interactive install tuned || rc=$?
        if [[ "${rc}" -ne 0 ]]; then
            if [[ "${rc}" -eq 106 || "${rc}" -eq 107 ]] && rpm -q tuned >/dev/null; then
                echo "WARN: zypper exited ${rc} but tuned is installed; continuing" >&2
            else
                exit "${rc}"
            fi
        fi
    ;;
    *)
        echo "Unsupported Distro: ${ID}"
        exit 1
    ;;
esac

# enable tuned service
systemctl enable --now tuned
systemctl status tuned
