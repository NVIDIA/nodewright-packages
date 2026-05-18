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

# cloud_init_cfg.sh: cloud-init / EC2 IMDS configuration for EKS nodes.
#
# Writes three drop-in files used by cloud-init on AWS:
#   1. /etc/cloud/cloud.cfg.d/99-dgxcloud.cfg            -- Ec2 datasource timeouts
#   2. /etc/systemd/system/cloud-init-local.service.d/   -- wait for ena/vif net device
#   3. /etc/udev/rules.d/10-ec2imds.rules                -- udev tag for dev-ec2imds.device
#
# Skyhook handles any service restarts; this step only writes the files.
# See https://github.com/canonical/cloud-init/issues/5289#issuecomment-2110873854

set -e

CLOUD_CFG_FILE="/etc/cloud/cloud.cfg.d/99-dgxcloud.cfg"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/cloud-init-local.service.d"
SYSTEMD_DROPIN_FILE="${SYSTEMD_DROPIN_DIR}/10-wait-for-net-device.conf"
UDEV_RULES_FILE="/etc/udev/rules.d/10-ec2imds.rules"

echo "=== cloud_init_cfg: write ${CLOUD_CFG_FILE} ==="
mkdir -p "$(dirname "${CLOUD_CFG_FILE}")"
cat <<'EOF' > "${CLOUD_CFG_FILE}"
datasource:
  Ec2:
    max_wait: 300
    timeout: 30
EOF

echo "=== cloud_init_cfg: write ${SYSTEMD_DROPIN_FILE} ==="
mkdir -p "${SYSTEMD_DROPIN_DIR}"
cat <<'EOF' > "${SYSTEMD_DROPIN_FILE}"
# cloud-init-local must wait for at least one network interface device to exist
# before attempting to download EC2 instance metadata.
#
# These systemd unit directives implement this policy along with
# /etc/udev/rules.d/10-ec2imds.rules

[Unit]
Requires=dev-ec2imds.device
After=dev-ec2imds.device
EOF

echo "=== cloud_init_cfg: write ${UDEV_RULES_FILE} ==="
mkdir -p "$(dirname "${UDEV_RULES_FILE}")"
cat <<'EOF' > "${UDEV_RULES_FILE}"
# cloud-init-local must wait for at least one network interface device to exist
# before attempting to download EC2 instance metadata.
#
# These udev rules implement this policy along with
# /etc/systemd/system/cloud-init-local.service.d/10-wait-for-net-device.conf

ACTION!="remove", SUBSYSTEM=="net", KERNEL!="lo", DRIVERS=="ena|vif", TAG+="systemd", ENV{SYSTEMD_ALIAS}+="/dev/ec2imds"
EOF

echo "=== cloud_init_cfg: done ==="
