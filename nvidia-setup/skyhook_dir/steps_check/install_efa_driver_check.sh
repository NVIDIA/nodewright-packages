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
# EFA installer typically installs to /opt/amazon/efa; check for presence
if [ -d /opt/amazon/efa ]; then
  exit 0
fi

# Fallback: check for libfabric or known EFA lib
if ldconfig -p 2>/dev/null | grep -q libfabric; then
  exit 0
fi

# Check DKMS
if dkms status | grep -q efa | grep -q "installed"; then
  exit 0
fi

echo "EFA driver not found (expected /opt/amazon/efa or libfabric)" >&2
exit 1
