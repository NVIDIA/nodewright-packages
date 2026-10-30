#!/usr/bin/env bash

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

# Test stand-in for `nvidia-ctk config --in-place --config=FILE --set KEY=VALUE...`.
# Writes top-level `key = value` lines the way nvidia-ctk does, replacing an
# existing assignment or appending a new one.

set -euo pipefail

[[ "${1:-}" == "config" ]] || { echo "fake nvidia-ctk: only 'config' is supported" >&2; exit 2; }
shift

config=""
sets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place) ;;
    --config=*) config="${1#--config=}" ;;
    --set) shift; sets+=("$1") ;;
    *) echo "fake nvidia-ctk: unexpected argument $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${config}" ]] || { echo "fake nvidia-ctk: --config is required" >&2; exit 2; }

for kv in "${sets[@]}"; do
  key="${kv%%=*}"
  value="${kv#*=}"
  if grep -q "^${key} = " "${config}"; then
    sed -i "s|^${key} = .*|${key} = ${value}|" "${config}"
  else
    # New top-level keys go before the first table header, as nvidia-ctk
    # writes them; appending would put them inside the last table.
    awk -v line="${key} = ${value}" '
      !done && /^[[:space:]]*\[/ { print line; done = 1 }
      { print }
      END { if (!done) print line }
    ' "${config}" > "${config}.new"
    mv "${config}.new" "${config}"
  fi
done
