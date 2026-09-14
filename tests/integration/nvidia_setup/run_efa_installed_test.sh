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

# Test harness for efa_driver_installed in utilities.sh. Set SCENARIO to pick a
# case. dpkg-query, dkms and ldconfig are stubbed, so nothing here inspects the
# real package database or the real filesystem.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

# -e on purpose: install-efa-driver.sh and install_efa_driver_check.sh both run
# under `set -e`, so efa_driver_installed must behave correctly with it active.
set -euo pipefail

SCENARIO="${SCENARIO:?SCENARIO must be set}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }

UTILITIES="${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
[ -f "${UTILITIES}" ] || { echo "utilities.sh not found at ${UTILITIES}" >&2; exit 1; }

# Stub dpkg-query: FAKE_EFA_PKG_STATE is the dpkg status of the efa package.
# Empty means dpkg does not know the package, which is what dpkg-query signals
# by exiting non-zero.
dpkg-query() {
  if [ -z "${FAKE_EFA_PKG_STATE:-}" ]; then
    echo "dpkg-query: no packages found matching efa" >&2
    return 1
  fi
  printf '%s' "${FAKE_EFA_PKG_STATE}"
}

# Stub dkms: FAKE_DKMS_STATUS is what `dkms status efa` prints.
dkms() {
  [ -n "${FAKE_DKMS_STATUS:-}" ] && printf '%s\n' "${FAKE_DKMS_STATUS}"
  return 0
}

# Stub ldconfig: the old guard treated any libfabric as proof of an EFA install.
ldconfig() {
  [ "${FAKE_LIBFABRIC:-false}" = "true" ] && echo "	libfabric.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libfabric.so.1"
  return 0
}

# shellcheck source=../../../nvidia-setup/skyhook_dir/utilities.sh
. "${UTILITIES}"

fail() { echo "FAIL (${SCENARIO}): $*" >&2; exit 1; }

case "${SCENARIO}" in
  # The only state that should count as installed.
  efa_installed)
    FAKE_EFA_PKG_STATE="installed"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed"
    efa_driver_installed || fail "a fully installed EFA must be reported as installed"
    ;;

  # The reported failure: the DKMS postinstall aborted, so dpkg parked the
  # package half-configured. EFA is not installed and must not be skipped.
  efa_half_configured)
    FAKE_EFA_PKG_STATE="half-configured"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed"
    efa_driver_installed && fail "a half-configured efa package is not an install"
    ;;

  efa_unpacked)
    FAKE_EFA_PKG_STATE="unpacked"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed"
    efa_driver_installed && fail "an unpacked efa package is not an install"
    ;;

  efa_absent)
    FAKE_EFA_PKG_STATE=""
    FAKE_DKMS_STATUS=""
    efa_driver_installed && fail "an absent efa package is not an install"
    ;;

  # The package is configured but the module was never built.
  efa_dkms_added_not_installed)
    FAKE_EFA_PKG_STATE="installed"
    FAKE_DKMS_STATUS="efa/3.0.0: added"
    efa_driver_installed && fail "a module that is added but not installed is not an install"
    ;;

  efa_dkms_no_entry)
    FAKE_EFA_PKG_STATE="installed"
    FAKE_DKMS_STATUS=""
    efa_driver_installed && fail "no dkms entry means the module is not installed"
    ;;

  # Regression guards for the two signals the old guard trusted. Both were
  # present on the node that reported success with a broken EFA.
  efa_leftover_directory_is_not_proof)
    mkdir -p /opt/amazon/efa 2>/dev/null || true
    FAKE_EFA_PKG_STATE="half-configured"
    FAKE_DKMS_STATUS=""
    efa_driver_installed && fail "/opt/amazon/efa existing must not count as installed"
    ;;

  efa_libfabric_is_not_proof)
    FAKE_LIBFABRIC="true"
    FAKE_EFA_PKG_STATE=""
    FAKE_DKMS_STATUS=""
    efa_driver_installed && fail "an unrelated libfabric must not count as installed"
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
