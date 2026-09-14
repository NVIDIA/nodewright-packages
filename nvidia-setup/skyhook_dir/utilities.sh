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

# resolve_full_kernel for nvidia-setup (skyhook): no get_var; use KERNEL and architecture.
# The conf (defaults/<service>-<accelerator>.conf) already specifies the exact kernel
# flavor (e.g. 6.17.0-1019-aws), so the only thing left to resolve is the
# architecture-specific page-size variant: arm64/aarch64 nodes (e.g. GB200/Grace) use
# the -64k kernel, x86_64 nodes use the flavor as-is.
# Usage: resolve_full_kernel <base_kernel_version>
# Returns: <conf_kernel>[-64k]
resolve_full_kernel() {
  local base_version="$1"
  if [ -z "${base_version}" ]; then
    base_version="${KERNEL:-}"
  fi
  if [ -z "${base_version}" ]; then
    echo "ERROR: kernel version not set" >&2
    return 1
  fi
  # arm64 uses the 64k page-size kernel; append -64k unless the conf already has it.
  local arch
  arch=$(uname -m)
  case "${arch}" in
    arm64 | aarch64)
      case "${base_version}" in
        *-64k) echo "${base_version}" ;;
        *)     echo "${base_version}-64k" ;;
      esac
      ;;
    *)
      echo "${base_version}"
      ;;
  esac
}

# Detect a dpkg database that needs `dpkg --configure -a` before apt will do
# anything. apt refuses up front with "E: dpkg was interrupted, you must
# manually run 'dpkg --configure -a' to correct the problem.", and that refusal
# happens on any apt command that takes the dpkg lock, `apt-get update`
# included, so guarding only the install paths is not enough.
#
# Two independent signals, either of which means a repair is warranted:
#   1. Numerically-named journal files left in <admindir>/updates/. This is
#      apt's own trigger (debSystem::CheckUpdates).
#   2. Packages parked in half-installed, unpacked or half-configured, which
#      can outlive the journal.
# Honours DPKG_ADMINDIR the same way dpkg does, which is also what makes this
# testable without touching the real database.
# Returns: 0 when dpkg needs repairing, 1 when it is healthy.
dpkg_needs_configure() {
  local admindir="${DPKG_ADMINDIR:-/var/lib/dpkg}"
  local entry

  for entry in "${admindir}/updates"/*; do
    [ -f "${entry}" ] || continue
    case "${entry##*/}" in
      *[!0-9]*) continue ;;
      *) return 0 ;;
    esac
  done

  if command -v dpkg-query >/dev/null 2>&1; then
    if dpkg-query -f '${db:Status-Status}\n' -W 2>/dev/null \
      | grep -qx -e half-installed -e unpacked -e half-configured; then
      return 0
    fi
  fi

  return 1
}

# Run an apt (or dpkg) command, repairing an interrupted dpkg state and retrying
# once when that is why it failed. Wrap every apt invocation with this: a node
# that was interrupted mid-install fails the next step that touches apt, which
# is rarely the step that caused it.
#
# The retry decision comes from the dpkg database rather than from grepping
# apt's output, so an unrelated failure that merely mentions dpkg is propagated
# untouched, and output is left to stream instead of being captured, so a long
# `apt-get upgrade` still reports progress as it runs.
# Usage: apt_with_dpkg_heal apt-get update
apt_with_dpkg_heal() {
  local status=0
  "$@" || status=$?

  if [ "${status}" -eq 0 ]; then
    return 0
  fi

  if ! dpkg_needs_configure; then
    return "${status}"
  fi

  echo "nvidia-setup: '$*' failed and dpkg is in an interrupted state; running 'dpkg --configure -a' and retrying once..." >&2
  dpkg --configure -a
  "$@"
}
