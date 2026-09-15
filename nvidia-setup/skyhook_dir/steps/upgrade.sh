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
export DEBIAN_FRONTEND=noninteractive

# Load helpers (nvidia-setup skyhook_dir layout)
if [ -f "${SKYHOOK_DIR:-}/skyhook_dir/utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "$(dirname "$0")/../utilities.sh" ]; then
  # shellcheck source=../utilities.sh
  . "$(dirname "$0")/../utilities.sh"
else
  echo "ERROR: utilities.sh not found" >&2
  exit 1
fi

# Preserve local /etc/* edits and never prompt on conffile diffs during unattended upgrades.
APT_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)
# A blanket `apt-get upgrade` installs whatever the distro has queued, which on a
# node that has been up a while includes the container runtime. Upgrading containerd
# restarts it, and that kills the very pod running this step: the node goes NotReady
# mid-apply and dpkg is interrupted partway through a transaction. Off by default;
# set NVIDIA_SETUP_APT_UPGRADE=true to opt a node in.
NVIDIA_SETUP_APT_UPGRADE="${NVIDIA_SETUP_APT_UPGRADE:-false}"

apt_with_dpkg_heal apt-get update

if [ "${NVIDIA_SETUP_APT_UPGRADE}" = "true" ]; then
  if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
    apt_with_dpkg_heal apt-get "${APT_OPTS[@]}" upgrade -y
  else
    echo "Skipping system upgrade for test environment"
  fi
else
  echo "Skipping apt-get upgrade: NVIDIA_SETUP_APT_UPGRADE is '${NVIDIA_SETUP_APT_UPGRADE}', not 'true'"
fi

# Targeted, and deliberately not gated: these are the tools later steps need.
apt_with_dpkg_heal apt-get "${APT_OPTS[@]}" install -y curl git wget gpg
