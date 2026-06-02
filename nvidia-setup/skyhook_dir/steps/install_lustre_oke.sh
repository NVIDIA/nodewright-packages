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

STEP_FILES="${SKYHOOK_DIR}/skyhook_dir/steps/files/oke"
PKG_VER="${LUSTRE_PKG_VERSION:?}"
DKMS_NAME="${LUSTRE_DKMS_NAME:?}"
DKMS_VER="${LUSTRE_DKMS_VERSION:?}"
BASE_URL="${LUSTRE_ARTIFACTS_URL:?}"
WORKDIR=/opt/lustre-client

install_loader() {
  install -D -m 0755 "${STEP_FILES}/lustre-modules-setup"         /usr/bin/lustre-modules-setup
  install -D -m 0644 "${STEP_FILES}/lustre-modules-setup.service" /etc/systemd/system/lustre-modules-setup.service
  if [ -z "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
    systemctl daemon-reload
    systemctl enable lustre-modules-setup.service
    systemctl start lustre-modules-setup.service || true
  fi
}

if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  echo "Skipping Lustre package install for test environment (dkms=${DKMS_NAME}/${DKMS_VER})"
  install_loader
  exit 0
fi

case "$(dpkg --print-architecture)" in
  arm64) deb_arch="arm64" ;;
  *)     deb_arch="amd64" ;;
esac

UTIL_DEB="lustre-client-utils_${PKG_VER}_${deb_arch}.deb"
MODS_DEB="lustre-client-modules-dkms_${PKG_VER}_${deb_arch}.deb"

mkdir -p "${WORKDIR}"
if ! dpkg -l lustre-client-utils 2>/dev/null | grep -q '^ii'; then
  curl -fsSL "${BASE_URL}/${UTIL_DEB}" -o "${WORKDIR}/${UTIL_DEB}"
  apt-get install -y "${WORKDIR}/${UTIL_DEB}"
fi
if ! dpkg -l lustre-client-modules-dkms 2>/dev/null | grep -q '^ii'; then
  curl -fsSL "${BASE_URL}/${MODS_DEB}" -o "${WORKDIR}/${MODS_DEB}"
  apt-get install -y "${WORKDIR}/${MODS_DEB}"
fi
rm -f "${WORKDIR}"/*.deb

# Pre-build DKMS for the running kernel (rc 3 == already installed)
if ! find "/lib/modules/$(uname -r)" -name 'lnet.ko*' 2>/dev/null | grep -q .; then
  dkms install "${DKMS_NAME}/${DKMS_VER}" -k "$(uname -r)" || [ $? -eq 3 ]
fi

install_loader
echo "Lustre client installed (dkms=${DKMS_NAME}/${DKMS_VER})"
