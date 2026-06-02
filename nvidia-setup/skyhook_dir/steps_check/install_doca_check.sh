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
if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
  exit 0
fi
if ! dpkg -l doca-all 2>/dev/null | grep -q '^ii'; then
  echo "doca-all not installed" >&2
  exit 1
fi
if ! command -v mstflint >/dev/null 2>&1; then
  echo "mstflint not installed" >&2
  exit 1
fi
exit 0
