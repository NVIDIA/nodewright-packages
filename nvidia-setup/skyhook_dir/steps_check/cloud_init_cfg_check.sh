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

# cloud_init_cfg_check.sh: apply-check for cloud_init_cfg step.
# Verifies the three drop-in files exist and contain their key directives.

set -e

CLOUD_CFG_FILE="/etc/cloud/cloud.cfg.d/99-dgxcloud.cfg"
SYSTEMD_DROPIN_FILE="/etc/systemd/system/cloud-init-local.service.d/10-wait-for-net-device.conf"
UDEV_RULES_FILE="/etc/udev/rules.d/10-ec2imds.rules"

REQUIRED_FILES=(
  "${CLOUD_CFG_FILE}"
  "${SYSTEMD_DROPIN_FILE}"
  "${UDEV_RULES_FILE}"
)

missing=0
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "${f}" ]; then
    echo "cloud_init_cfg_check: missing required file: ${f}" >&2
    missing=1
  fi
done
if [ "${missing}" -ne 0 ]; then
  exit 1
fi

if ! grep -q "max_wait: 300" "${CLOUD_CFG_FILE}"; then
  echo "cloud_init_cfg_check: ${CLOUD_CFG_FILE} missing 'max_wait: 300'" >&2
  exit 1
fi

if ! grep -q "^Requires=dev-ec2imds.device" "${SYSTEMD_DROPIN_FILE}"; then
  echo "cloud_init_cfg_check: ${SYSTEMD_DROPIN_FILE} missing 'Requires=dev-ec2imds.device'" >&2
  exit 1
fi

if ! grep -q 'DRIVERS=="ena|vif"' "${UDEV_RULES_FILE}"; then
  echo "cloud_init_cfg_check: ${UDEV_RULES_FILE} missing 'DRIVERS==\"ena|vif\"' rule" >&2
  exit 1
fi

echo "cloud_init_cfg_check: ok"
