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

# prune_foreign_kernels [keep_version...]
#
# Purge every installed kernel except the running one, plus any additional
# kernel versions passed as arguments (e.g. a freshly installed target that is
# not yet booted). The running kernel is never removed.
#
# Why this exists: out-of-tree DKMS modules (EFA's efa, efa-nv-peermem) are
# built by `dkms autoinstall`, which the EFA .deb post-install runs for every
# installed kernel that still has headers. A single failing build there returns
# a dpkg error and aborts the whole EFA install. On Grace/arm64 the base AMI
# ships the 4k `-aws` flavour alongside the booted 64k `-aws-64k` kernel, and
# EFA 3.0.0's kcompat shims do not compile against the 4k arm64 headers: DKMS
# tries to build EFA for a kernel the node does not even run, and it fails.
#
# Removing only the concrete 4k kernel is NOT enough: its `linux-image-<sib>`
# meta package (e.g. linux-image-aws) then makes apt UPGRADE the meta and pull a
# fresh 4k kernel to satisfy it, so the build target reappears. This function
# therefore also purges the page-size sibling flavour's meta packages
# (linux-<sib>, linux-image-<sib>, linux-headers-<sib>, linux-tools-<sib>) in the
# same transaction, so the sibling flavour stays gone. The running flavour's own
# metas are always kept.
#
# When SKIP_SYSTEM_OPERATIONS is set the selection is logged but no apt
# operation runs (used by tests and dry runs).
prune_foreign_kernels() {
  local running
  running="$(uname -r)"
  if [ -z "${running}" ]; then
    echo "prune_foreign_kernels: could not determine running kernel; refusing to prune" >&2
    return 1
  fi

  local -a keep=("${running}" "$@")

  # Page-size flavour of each kept kernel (e.g. 6.17.0-1019-aws-64k -> aws-64k),
  # derived by stripping the leading "<upstream>-<abi>-".
  local -a keep_flavours=()
  local kv
  for kv in "${keep[@]}"; do
    keep_flavours+=("${kv#*-*-}")
  done

  # Concrete, versioned kernel images only (e.g. linux-image-6.17.0-1017-aws).
  # The [0-9] class right after the prefix skips meta packages such as
  # linux-image-aws / linux-image-aws-64k, which carry no version of their own.
  local -a versions=()
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] && versions+=("${line}")
  done < <(
    dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
      | sed -n 's/^linux-image-//p' || true
  )

  local -a foreign=()
  local ver k kept
  for ver in "${versions[@]}"; do
    [ -n "${ver}" ] || continue
    kept=0
    for k in "${keep[@]}"; do
      if [ "${ver}" = "${k}" ]; then
        kept=1
        break
      fi
    done
    [ "${kept}" -eq 1 ] || foreign+=("${ver}")
  done

  # Family packages for each foreign kernel version.
  local -a candidates=()
  for ver in "${foreign[@]}"; do
    candidates+=(
      "linux-image-${ver}"
      "linux-headers-${ver}"
      "linux-modules-${ver}"
      "linux-modules-extra-${ver}"
    )
  done

  # Sibling-flavour meta packages. When the running kernel is a 64k flavour, its
  # 4k page-size sibling (aws-64k -> aws) is never used on this node; purge that
  # sibling's metas so apt cannot re-pull a 4k kernel to satisfy them. Skip if the
  # sibling flavour is itself something we are keeping.
  local running_flavour="${running#*-*-}"
  case "${running_flavour}" in
    *-64k)
      local sib="${running_flavour%-64k}"
      local keep_sib=0 kf
      for kf in "${keep_flavours[@]}"; do
        if [ "${kf}" = "${sib}" ]; then
          keep_sib=1
          break
        fi
      done
      if [ "${keep_sib}" -eq 0 ]; then
        candidates+=(
          "linux-${sib}"
          "linux-image-${sib}"
          "linux-headers-${sib}"
          "linux-tools-${sib}"
        )
      fi
      ;;
  esac

  # Keep only packages that are actually installed, so a missing family member
  # (e.g. a kernel with no linux-modules-extra, or an absent sibling meta) is not
  # an "Unable to locate package" hard error.
  local -a purge=()
  local p
  for p in "${candidates[@]}"; do
    if dpkg-query -W -f='${Status}\n' "${p}" 2>/dev/null | grep -q 'ok installed'; then
      purge+=("${p}")
    fi
  done

  if [ "${#purge[@]}" -eq 0 ]; then
    echo "prune_foreign_kernels: nothing to prune (keeping: ${keep[*]})"
    return 0
  fi

  echo "prune_foreign_kernels: keeping ${keep[*]}; purging ${purge[*]}"

  if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
    echo "prune_foreign_kernels: SKIP_SYSTEM_OPERATIONS set; would purge: ${purge[*]}"
    return 0
  fi

  # Purge the concrete foreign kernels and the sibling metas together so apt
  # removes the meta instead of upgrading it and re-pulling a sibling kernel.
  DEBIAN_FRONTEND=noninteractive apt-get purge -y "${purge[@]}"
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge
}
