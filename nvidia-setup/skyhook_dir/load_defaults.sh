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

# Load nvidia-setup defaults and env overrides. Source this from apply.sh, apply_check.sh,
# kernel_install_check.sh, and any other script that needs SERVICE, ACCELERATOR, KERNEL, LUSTRE, EFA.
# Requires: SKYHOOK_DIR set.
# Sets and exports: CONFIGMAP_DIR, DEFAULTS_DIR, SERVICE, ACCELERATOR, COMBINATION, KERNEL_FLAVOR,
# KERNEL_TRACK, KERNEL, LUSTRE, EFA, EFA_DRIVER.
#
# KERNEL comes from the kernel catalog (kernels.conf): the combination's KERNEL_FLAVOR plus
# its track (lts or hwe) for the node's Ubuntu release. The one exception is the deprecated
# NVIDIA_KERNEL, which skips the catalog until its removal in 0.12.0. The catalog sits outside
# defaults/ because every *.conf there is listed as a combination.

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
DEFAULTS_DIR="${SKYHOOK_DIR}/skyhook_dir/defaults"
KERNELS_FILE="${SKYHOOK_DIR}/skyhook_dir/kernels.conf"

SERVICE=$(cat "${CONFIGMAP_DIR}/service")
ACCELERATOR=$(cat "${CONFIGMAP_DIR}/accelerator")
COMBINATION="${SERVICE}-${ACCELERATOR}"
DEFAULTS_FILE="${DEFAULTS_DIR}/${COMBINATION}.conf"

if [ ! -f "${DEFAULTS_FILE}" ]; then
  echo "Unsupported combination: service=${SERVICE} accelerator=${ACCELERATOR}" >&2
  echo "Supported: $(find "${DEFAULTS_DIR}" -maxdepth 1 -name '*.conf' -exec basename {} .conf \; 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# The defaults file names a kernel flavor and, per Ubuntu release, a track (lts or hwe),
# never a kernel; start them empty so nothing leaks in from the environment.
KERNEL=""
KERNEL_FLAVOR=""
KERNEL_TRACK=""
for var in $(compgen -v KERNEL_TRACK_); do unset "${var}"; done

# shellcheck source=/dev/null
. "${DEFAULTS_FILE}"

if [[ -n "${KERNEL}" ]]; then
  echo "${DEFAULTS_FILE} sets KERNEL=${KERNEL}; set KERNEL_FLAVOR= and KERNEL_TRACK_<release>= and add the kernel to ${KERNELS_FILE}" >&2
  exit 1
fi

# A CR's track choice: the kernel_track configmap key, then NVIDIA_KERNEL_TRACK (env wins,
# like the other NVIDIA_* overrides).
track_override=""
if [[ -f "${CONFIGMAP_DIR}/kernel_track" ]]; then
  track_override="$(tr -d '[:space:]' < "${CONFIGMAP_DIR}/kernel_track")"
fi
[[ -n "${NVIDIA_KERNEL_TRACK:-}" ]] && track_override="${NVIDIA_KERNEL_TRACK}"

if [[ -n "${NVIDIA_KERNEL:-}" ]]; then
  # NVIDIA_KERNEL is deprecated: still honored in 0.11.x, removed in 0.12.0.
  # It names an exact kernel, so it wins over any track and skips the catalog.
  echo "WARNING: NVIDIA_KERNEL is deprecated and will be removed in nvidia-setup 0.12.0;" \
    "select lts or hwe with NVIDIA_KERNEL_TRACK or the kernel_track configmap key" >&2
  KERNEL="${NVIDIA_KERNEL}"
elif [[ -n "${KERNEL_FLAVOR}" ]]; then
  # Which kernel a SKU runs depends on the Ubuntu release: an H100 runs noble's hwe kernel
  # (7.0) but would run resolute's lts kernel (also 7.0), while newer hardware follows hwe.
  OS_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ ! "${OS_CODENAME}" =~ ^[a-z]+$ ]]; then
    echo "Cannot select a kernel: no usable VERSION_CODENAME in /etc/os-release (got '${OS_CODENAME}')" >&2
    exit 1
  fi
  # The tracks this package version has a kernel for on this release. None means the release
  # is not supported at all, so no override can help.
  available="$(awk -v flavor="${KERNEL_FLAVOR}" -v release="${OS_CODENAME}" \
    '$1 !~ /^#/ && NF >= 4 && $1 == flavor && $3 == release { print $2 }' "${KERNELS_FILE}" | tr '\n' ' ')"
  available="${available% }"
  if [[ -z "${available}" ]]; then
    echo "This nvidia-setup version has no ${KERNEL_FLAVOR} kernel for Ubuntu ${OS_CODENAME}, so ${COMBINATION} is not supported there" >&2
    exit 1
  fi

  track_var="KERNEL_TRACK_${OS_CODENAME}"
  KERNEL_TRACK="${!track_var:-}"
  [[ -n "${track_override}" ]] && KERNEL_TRACK="${track_override}"

  if [[ -z "${KERNEL_TRACK}" ]]; then
    echo "${COMBINATION} has no kernel track for Ubuntu ${OS_CODENAME}; set the kernel_track configmap key or NVIDIA_KERNEL_TRACK to one of: ${available}" >&2
    exit 1
  fi
  if [[ "${KERNEL_TRACK}" != "lts" && "${KERNEL_TRACK}" != "hwe" ]]; then
    echo "Unknown kernel track: ${KERNEL_TRACK} (valid: lts, hwe)" >&2
    exit 1
  fi

  KERNEL="$(awk -v flavor="${KERNEL_FLAVOR}" -v track="${KERNEL_TRACK}" -v release="${OS_CODENAME}" \
    '$1 !~ /^#/ && NF >= 4 && $1 == flavor && $2 == track && $3 == release { print $4; exit }' "${KERNELS_FILE}")"
  if [[ -z "${KERNEL}" ]]; then
    echo "No ${KERNEL_FLAVOR} ${KERNEL_TRACK} kernel for Ubuntu ${OS_CODENAME} in kernels.conf" >&2
    echo "Available for ${OS_CODENAME}: ${available}" >&2
    exit 1
  fi
elif [[ -n "${track_override}" ]]; then
  echo "${COMBINATION} does not manage the kernel; remove kernel_track / NVIDIA_KERNEL_TRACK" >&2
  exit 1
fi
unset track_override track_var var available

# Env overrides
[ -n "${NVIDIA_LUSTRE:-}" ] && LUSTRE="${NVIDIA_LUSTRE}"
[ -n "${NVIDIA_EFA:-}" ] && EFA="${NVIDIA_EFA}"
[ -n "${NVIDIA_EFA_DRIVER:-}" ] && EFA_DRIVER="${NVIDIA_EFA_DRIVER}"

# EFA names the installer; EFA_DRIVER is the efa driver version it ships, which
# is what dkms reports and what decides whether EFA is current. The defaults
# file's EFA_DRIVER belongs to its own installer, so an installer override has
# to bring the driver version with it.
if [ -n "${NVIDIA_EFA:-}" ] && [ -z "${NVIDIA_EFA_DRIVER:-}" ]; then
  echo "NVIDIA_EFA=${NVIDIA_EFA} needs NVIDIA_EFA_DRIVER, the efa driver version that installer ships" >&2
  exit 1
fi
if [ -n "${EFA:-}" ] && [ -z "${EFA_DRIVER:-}" ]; then
  echo "EFA=${EFA} needs EFA_DRIVER, the efa driver version that installer ships (set NVIDIA_EFA_DRIVER)" >&2
  exit 1
fi

export CONFIGMAP_DIR DEFAULTS_DIR SERVICE ACCELERATOR COMBINATION KERNEL_FLAVOR KERNEL_TRACK KERNEL LUSTRE EFA EFA_DRIVER
