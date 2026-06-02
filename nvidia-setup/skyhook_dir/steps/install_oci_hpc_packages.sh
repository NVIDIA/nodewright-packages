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

set -eo pipefail

# shellcheck source=../load_defaults.sh
. "${SKYHOOK_DIR}/skyhook_dir/load_defaults.sh"
export DEBIAN_FRONTEND=noninteractive

NET_VER="${OCI_HPC_NET_DEVICE_NAMES_VERSION:?}"
GPU_VER="${OCI_HPC_GPU_CONFIGURE_VERSION:?}"
BASE_URL="${OCI_HPC_ARTIFACTS_URL:?}"
WORKDIR=/opt/oci-hpc-packages

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "Skipping OCI HPC package install for test environment (net=${NET_VER} gpu=${GPU_VER})"
  exit 0
fi

apt-get update
apt-get install -y ifupdown

case "$(uname -m)" in
  aarch64) arch_suffix="aarch64" ;;
  *)       arch_suffix="x86_64" ;;
esac

NET_DEB="oci-hpc-network-device-names-${NET_VER}.${arch_suffix}.deb"
GPU_DEB="oci-hpc-nvidia-gpu-configure_${GPU_VER}-compute_all.deb"

mkdir -p "${WORKDIR}"
# Idempotent: skip if already installed
if ! dpkg -l oci-hpc-network-device-names 2>/dev/null | grep -q '^ii'; then
  curl -fsSL "${BASE_URL}/${NET_DEB}" -o "${WORKDIR}/${NET_DEB}"
  apt-get install -y "${WORKDIR}/${NET_DEB}"
fi
if ! dpkg -l oci-hpc-nvidia-gpu-configure 2>/dev/null | grep -q '^ii'; then
  curl -fsSL "${BASE_URL}/${GPU_DEB}" -o "${WORKDIR}/${GPU_DEB}"
  apt-get install -y "${WORKDIR}/${GPU_DEB}"
fi
rm -f "${WORKDIR}"/*.deb
echo "OCI HPC packages installed (net=${NET_VER} gpu=${GPU_VER})"
