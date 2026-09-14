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

# Test harness for dpkg_needs_configure and apt_with_dpkg_heal in utilities.sh.
#
# Set SCENARIO to pick a case. dpkg, dpkg-query and the wrapped command are all
# stubbed, and DPKG_ADMINDIR points at a scratch tree, so nothing here touches
# the real package database.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

set -uo pipefail

SCENARIO="${SCENARIO:?SCENARIO must be set}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }

UTILITIES="${SKYHOOK_DIR}/skyhook_dir/utilities.sh"
[ -f "${UTILITIES}" ] || { echo "utilities.sh not found at ${UTILITIES}" >&2; exit 1; }

DPKG_ADMINDIR="$(mktemp -d)"
export DPKG_ADMINDIR
mkdir -p "${DPKG_ADMINDIR}/updates"
trap 'rm -rf "${DPKG_ADMINDIR}"' EXIT

REPAIR_LOG="${DPKG_ADMINDIR}/repair.log"
ATTEMPT_LOG="${DPKG_ADMINDIR}/attempts.log"
: > "${REPAIR_LOG}"
: > "${ATTEMPT_LOG}"

# Stub dpkg: record that `dpkg --configure -a` ran, and clear the journal so the
# retry sees a repaired database, exactly as the real command would.
dpkg() {
  if [ "${1:-}" = "--configure" ] && [ "${2:-}" = "-a" ]; then
    echo "configure-a" >> "${REPAIR_LOG}"
    rm -f "${DPKG_ADMINDIR}/updates"/*
    return 0
  fi
  return 0
}

# Stub dpkg-query: no half-configured packages unless a scenario says otherwise.
dpkg-query() {
  printf '%s\n' "${FAKE_PKG_STATES:-installed}"
}

# Stub apt-get: fails until the dpkg journal is gone, so a run only succeeds
# once a repair has happened. FORCE_FAIL makes it fail unconditionally.
apt-get() {
  echo "apt-get $*" >> "${ATTEMPT_LOG}"
  if [ "${FORCE_FAIL:-false}" = "true" ]; then
    echo "E: something unrelated went wrong" >&2
    return 100
  fi
  if compgen -G "${DPKG_ADMINDIR}/updates/*" > /dev/null; then
    echo "E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem." >&2
    return 100
  fi
  return 0
}

# shellcheck source=../../../nvidia-setup/skyhook_dir/utilities.sh
. "${UTILITIES}"

fail() { echo "FAIL (${SCENARIO}): $*" >&2; exit 1; }

attempts() { wc -l < "${ATTEMPT_LOG}" | tr -d ' '; }
repairs()  { wc -l < "${REPAIR_LOG}"  | tr -d ' '; }

case "${SCENARIO}" in
  # dpkg_needs_configure: a numerically-named journal file is apt's own trigger.
  needs_configure_journal)
    touch "${DPKG_ADMINDIR}/updates/0001"
    dpkg_needs_configure || fail "expected an interrupted state to be detected"
    ;;

  # A non-numeric leftover is not a dpkg journal and must not trigger a repair.
  needs_configure_ignores_non_journal)
    touch "${DPKG_ADMINDIR}/updates/tmp.txt"
    dpkg_needs_configure && fail "a non-journal file must not count as interrupted"
    ;;

  needs_configure_clean)
    dpkg_needs_configure && fail "a clean database must not report as interrupted"
    ;;

  # Half-configured packages need `dpkg --configure -a` even with no journal.
  needs_configure_half_configured)
    FAKE_PKG_STATES="half-configured"
    dpkg_needs_configure || fail "expected half-configured packages to be detected"
    ;;

  # The happy path must not repair or retry.
  heal_noop_on_success)
    apt_with_dpkg_heal apt-get update || fail "expected success"
    [ "$(attempts)" = "1" ] || fail "expected 1 attempt, got $(attempts)"
    [ "$(repairs)" = "0" ] || fail "expected no repair, got $(repairs)"
    ;;

  # The reported bug: apt-get update refuses because dpkg was interrupted.
  heal_recovers_apt_update)
    touch "${DPKG_ADMINDIR}/updates/0001"
    apt_with_dpkg_heal apt-get update || fail "expected recovery to succeed"
    [ "$(repairs)" = "1" ] || fail "expected exactly 1 repair, got $(repairs)"
    [ "$(attempts)" = "2" ] || fail "expected 2 attempts, got $(attempts)"
    ;;

  heal_recovers_apt_install)
    touch "${DPKG_ADMINDIR}/updates/0001"
    apt_with_dpkg_heal apt-get install -y curl || fail "expected recovery to succeed"
    [ "$(repairs)" = "1" ] || fail "expected exactly 1 repair, got $(repairs)"
    grep -q 'install -y curl' "${ATTEMPT_LOG}" || fail "retry lost the original arguments"
    ;;

  # An unrelated failure must propagate, not be masked by a repair-and-retry.
  heal_propagates_unrelated_failure)
    FORCE_FAIL=true
    status=0
    apt_with_dpkg_heal apt-get update || status=$?
    [ "${status}" = "100" ] || fail "expected exit 100 to be preserved, got ${status}"
    [ "$(repairs)" = "0" ] || fail "must not repair when dpkg is healthy"
    [ "$(attempts)" = "1" ] || fail "must not retry when dpkg is healthy"
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
