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
F=/etc/security/limits.d/99-oci-hpc.conf
if [ ! -f "${F}" ]; then echo "Missing ${F}" >&2; exit 1; fi
grep -Eq '^\*[[:space:]]+hard[[:space:]]+memlock[[:space:]]+unlimited' "${F}" || {
  echo "memlock hard unlimited not set in ${F}" >&2; exit 1; }
exit 0
