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
KERNEL_VERSION="${1:?kernel version required}"
LUSTRE="${2:-aws}"
# shellcheck source=../utilities.sh
# Try multiple paths to find utilities.sh
if [ -f "${SKYHOOK_DIR}/skyhook_dir/utilities.sh" ]; then
  . "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
elif [ -f "${SKYHOOK_DIR}/utilities.sh" ]; then
  . "${SKYHOOK_DIR}/utilities.sh"
else
  # Fallback to relative path from script location
  . "$(dirname "$0")/../utilities.sh"
fi

install_from_aws() {
  local KVER="$1"
  local FULL_KERNEL_VER
  FULL_KERNEL_VER="$(resolve_full_kernel "${KVER}")"
  mkdir -m 0755 -p /etc/apt/keyrings/
  wget -q -O - https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-ubuntu-public-key.asc \
    | gpg --dearmor -o /etc/apt/keyrings/fsx-ubuntu-public-key.gpg
  chmod -R 0755 /etc/apt/keyrings
  echo "deb [signed-by=/etc/apt/keyrings/fsx-ubuntu-public-key.gpg] https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu jammy main" \
    | tee /etc/apt/sources.list.d/fsxlustreclientrepo.list > /dev/null && apt-get update
  echo "Installing lustre from AWS repo for kernel ${FULL_KERNEL_VER} ..."
  if apt-cache show "lustre-client-modules-${FULL_KERNEL_VER}" >/dev/null 2>&1; then
    if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
    apt install -y "lustre-client-modules-${FULL_KERNEL_VER}"
    else
      echo "Skipping lustre install for test environment. Selected ${FULL_KERNEL_VER}"
    fi
  else
    lustre_package=$(apt-cache search "lustre-client-modules-${KVER}" | sort -r | awk '{print $1; exit}')
    if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
      apt install -y "${lustre_package}"
    else
      echo "Skipping lustre install for test environment. Selected ${lustre_package}"
    fi
  fi
}

build_from_source() {
  local KVER="$1"
  local LUSTRE_REF="$2"
  local FULL_KERNEL_VER
  FULL_KERNEL_VER="$(resolve_full_kernel "${KVER}")"
  local HEADERS_PATH="/usr/src/linux-headers-${FULL_KERNEL_VER}"
  echo "Building lustre '${LUSTRE_REF}' for kernel ${FULL_KERNEL_VER} ..."
  apt-get update
  BUILD_DEPS="flex bison libyaml-dev libyaml-cpp-dev libnl-3-dev libnl-genl-3-dev \
libreadline-dev pkg-config git gcc-12 g++-12 libtool quilt automake autoconf \
module-assistant debhelper rsync libpython3-dev swig libext2fs-dev libkeyutils-dev libaio-dev \
libmount-dev libssl-dev libselinux1-dev linux-headers-generic build-essential"
  REMOVE_DEPS=""
  for pkg in ${BUILD_DEPS}; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      REMOVE_DEPS="${REMOVE_DEPS} ${pkg}"
    fi
  done
  if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  apt-get install -y -o DPkg::Lock::Timeout=60 --no-install-recommends \
    -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" ${BUILD_DEPS}
  else
    echo "Skipping build dependencies install for test environment."
  fi
  DEST="$(mktemp -d -t lustre.XXXXXXXX)" || DEST="/tmp/lustre.$$"
  trap 'rm -rf "$DEST"' EXIT
  export DEST CC=gcc-12 CXX=g++-12
  mkdir -p "${DEST}" && cd "${DEST}"
  git clone -b "${LUSTRE_REF}" --single-branch https://github.com/lustre/lustre-release.git
  if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
    cd lustre-release
    sh autogen.sh
    ./configure --with-linux="${HEADERS_PATH}" --disable-server
    make -j"$(nproc)" debs
    dpkg -i debs/lustre-client-modules-${FULL_KERNEL_VER}_*.deb
    if [ -n "${REMOVE_DEPS// }" ]; then
      apt-get purge -y ${REMOVE_DEPS}
    fi
  else
    echo "Skipping lustre build for test environment."
    echo "Selected kernel: ${FULL_KERNEL_VER}"
    echo "Selected lustre: ${LUSTRE_REF}"
  fi
}

if [ "${LUSTRE}" = "aws" ]; then
  install_from_aws "${KERNEL_VERSION}"
else
  build_from_source "${KERNEL_VERSION}" "${LUSTRE}"
fi
