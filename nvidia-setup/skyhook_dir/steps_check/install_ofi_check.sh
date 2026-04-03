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


if [ ! -f /etc/profile.d/ofi-aws.sh ]; then
  echo "ERROR: /etc/profile.d/ofi-aws.sh not found"
  exit 1
fi

if [ ! -f /etc/ld.so.conf.d/000_ofi_aws.conf ]; then
  echo "ERROR: /etc/ld.so.conf.d/000_ofi_aws.conf not found"
  exit 1
fi

if [ ! -d /opt/amazon/ofi-nccl ]; then
  echo "ERROR: /opt/amazon/ofi-nccl not found"
  exit 1
fi
