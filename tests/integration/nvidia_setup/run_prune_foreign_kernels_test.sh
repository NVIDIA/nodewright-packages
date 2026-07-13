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

# Test harness for prune_foreign_kernels in utilities.sh.
#
# Inputs (env):
#   RUNNING_KERNEL     - value returned by `uname -r` (required)
#   INSTALLED_PACKAGES - space-separated list of installed kernel-related package
#                        names (concrete kernels AND flavour meta packages) that
#                        the mocked dpkg-query should report. The enumeration
#                        query returns the linux-image-<version> entries; the
#                        status query reports any listed package as installed.
#   KEEP_EXTRA         - optional space-separated extra kernel versions to keep
#                        (e.g. a freshly installed target not yet booted)
#
# Mocks uname and dpkg-query, sources utilities.sh, and runs prune_foreign_kernels
# with SKIP_SYSTEM_OPERATIONS set so no apt operation runs; the resolved purge set
# is printed to stdout for the caller to assert on. Exit code mirrors the function.
set -e

RUNNING_KERNEL="${RUNNING_KERNEL:?RUNNING_KERNEL must be set}"
INSTALLED_PACKAGES="${INSTALLED_PACKAGES:-}"
KEEP_EXTRA="${KEEP_EXTRA:-}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }

uname() {
  if [ "$1" = "-r" ]; then
    echo "${RUNNING_KERNEL}"
  else
    /usr/bin/uname "$@"
  fi
}

# Mock dpkg-query for the two shapes prune_foreign_kernels uses:
#   enumeration:  -W -f='${Package}\n' 'linux-image-[0-9]*'  -> installed images
#   status query: -W -f='${Status}\n' <package>              -> "install ok installed"
dpkg-query() {
  if printf '%s\n' "$@" | grep -q 'Package'; then
    local pkg
    for pkg in ${INSTALLED_PACKAGES}; do
      case "${pkg}" in
        linux-image-[0-9]*) echo "${pkg}" ;;
      esac
    done
    return 0
  fi
  local want
  for want in "$@"; do :; done
  local q
  for q in ${INSTALLED_PACKAGES}; do
    if [ "${q}" = "${want}" ]; then
      echo "install ok installed"
      return 0
    fi
  done
  return 1
}

# Force dry-run: the harness only exercises the selection logic, never apt.
export SKIP_SYSTEM_OPERATIONS=1

# shellcheck source=/dev/null
. "${SKYHOOK_DIR}/skyhook_dir/utilities.sh"

# KEEP_EXTRA is an intentional word-split list of extra versions to keep.
# shellcheck disable=SC2086
prune_foreign_kernels ${KEEP_EXTRA}
exit $?
