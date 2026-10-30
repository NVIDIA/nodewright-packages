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

# Test harness for dpkg_needs_configure and apt_with_dpkg_heal in utilities.sh.
#
# Set SCENARIO to pick a case. dpkg, dpkg-query and the wrapped command are all
# stubbed, and DPKG_ADMINDIR points at a scratch tree, so nothing here touches
# the real package database.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

# -e on purpose: the step scripts that source utilities.sh all run under `set -e`,
# so the helpers must behave correctly with it active. Expected-failure paths in
# the scenarios below use `||` or a condition, which `set -e` does not trip on.
set -euo pipefail

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
DKMS_LOG="${DPKG_ADMINDIR}/dkms.log"
APT_CONFIG_LOG="${DPKG_ADMINDIR}/apt-config.log"
LOCALE_LOG="${DPKG_ADMINDIR}/locale.log"
CLEARED_MARKER="${DPKG_ADMINDIR}/dkms-cleared"
: > "${REPAIR_LOG}"
: > "${ATTEMPT_LOG}"
: > "${DKMS_LOG}"
: > "${APT_CONFIG_LOG}"
: > "${LOCALE_LOG}"

# A held lock is retried after the shortest pause rather than the production one.
export APT_LOCK_RETRY_INTERVAL_SECONDS=1

# Stub dpkg. `dpkg --configure -a` clears the journal the way the real command
# would. DKMS_CONFLICT reproduces a postinst that aborts on a stale DKMS tree
# entry: it keeps failing, identically, until the entry is removed. The first
# DPKG_LOCK_HELD_ATTEMPTS runs fail the way dpkg does while another process
# holds its frontend lock.
dpkg() {
  if [ "${1:-}" = "--configure" ] && [ "${2:-}" = "-a" ]; then
    echo "configure-a" >> "${REPAIR_LOG}"

    if [ "$(repairs)" -le "${DPKG_LOCK_HELD_ATTEMPTS:-0}" ]; then
      echo "dpkg: error: dpkg frontend lock was locked by another process with pid 4242" >&2
      return 2
    fi

    if [ -n "${DKMS_CONFLICT:-}" ] && [ ! -f "${CLEARED_MARKER}" ]; then
      echo "Setting up the package ..."
      echo "Error! DKMS tree already contains: ${DKMS_CONFLICT}" >&2
      echo "You cannot add the same module/version combo more than once." >&2
      echo "dpkg: error processing package (--configure):" >&2
      return 1
    fi

    if [ "${CONFIGURE_FAILS_UNRELATED:-false}" = "true" ]; then
      echo "dpkg: dependency problems prevent configuration" >&2
      return 1
    fi

    rm -f "${DPKG_ADMINDIR}/updates"/*
    return 0
  fi
  return 0
}

# Stub dpkg-query: no half-configured packages unless a scenario says otherwise.
dpkg-query() {
  printf '%s\n' "${FAKE_PKG_STATES:-installed}"
}

# Stub dkms. `dkms status` returns whatever the scenario staged; `dkms remove`
# records the exact arguments and clears the conflict.
dkms() {
  case "${1:-}" in
    status)
      [ -n "${FAKE_DKMS_STATUS:-}" ] && printf '%s\n' "${FAKE_DKMS_STATUS}"
      ;;
    remove)
      shift
      echo "remove $*" >> "${DKMS_LOG}"
      if [ "${FAIL_DKMS_REMOVE:-false}" = "true" ]; then
        echo "Error! Could not remove module." >&2
        return 1
      fi
      touch "${CLEARED_MARKER}"
      ;;
  esac
  return 0
}

# Stub apt-get: fails while the dpkg journal is present or a DKMS conflict is
# outstanding, so a run only succeeds once the right repair has happened.
# FORCE_FAIL makes it fail unconditionally, for an unrelated-failure scenario.
# The first LOCK_HELD_ATTEMPTS runs fail the way apt does while another process
# holds the lists lock. It records the APT_CONFIG and LC_ALL it was handed.
apt-get() {
  echo "apt-get $*" >> "${ATTEMPT_LOG}"
  echo "${LC_ALL:-}" >> "${LOCALE_LOG}"
  if [ -n "${APT_CONFIG:-}" ] && [ -f "${APT_CONFIG}" ]; then
    cat "${APT_CONFIG}" >> "${APT_CONFIG_LOG}"
  fi
  if [ "$(attempts)" -le "${LOCK_HELD_ATTEMPTS:-0}" ]; then
    echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4242 (apt)" >&2
    return 100
  fi
  if [ "${FORCE_FAIL:-false}" = "true" ]; then
    echo "E: something unrelated went wrong" >&2
    return 100
  fi
  if [ -n "${DKMS_CONFLICT:-}" ] && [ ! -f "${CLEARED_MARKER}" ]; then
    echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" >&2
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
removals() { wc -l < "${DKMS_LOG}"    | tr -d ' '; }

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

  # Packages parked mid-operation need `dpkg --configure -a` even with no journal.
  needs_configure_half_configured)
    FAKE_PKG_STATES="half-configured"
    dpkg_needs_configure || fail "expected half-configured packages to be detected"
    ;;

  needs_configure_half_installed)
    FAKE_PKG_STATES="half-installed"
    dpkg_needs_configure || fail "expected half-installed packages to be detected"
    ;;

  needs_configure_unpacked)
    FAKE_PKG_STATES="unpacked"
    dpkg_needs_configure || fail "expected unpacked packages to be detected"
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

  # nvidia-tuned's apply runs alongside nvidia-setup-kernel and holds the apt
  # lists lock for a few seconds; apt itself does not wait for that lock.
  lock_retry_waits_for_a_held_lock)
    LOCK_HELD_ATTEMPTS=2
    apt_with_dpkg_heal apt-get update || fail "expected the run to succeed once the lock is free"
    [ "$(attempts)" = "3" ] || fail "expected 3 attempts, got $(attempts)"
    [ "$(repairs)" = "0" ] || fail "a held lock is not an interrupted dpkg; got $(repairs) repairs"
    ;;

  lock_retry_gives_up_after_the_budget)
    LOCK_HELD_ATTEMPTS=1000
    export APT_LOCK_WAIT_SECONDS=2 APT_LOCK_RETRY_INTERVAL_SECONDS=1
    start=$(date +%s)
    status=0
    apt_with_dpkg_heal apt-get update || status=$?
    [ "${status}" = "100" ] || fail "expected apt's exit 100 once the budget is spent, got ${status}"
    [ $(( $(date +%s) - start )) -le 6 ] || fail "kept retrying past the budget"
    [ "$(attempts)" -ge 2 ] || fail "expected at least one retry, got $(attempts) attempts"
    ;;

  # apt does wait for the dpkg frontend lock itself, given DPkg::Lock::Timeout.
  lock_retry_passes_the_remaining_budget_to_apt)
    apt_with_dpkg_heal apt-get install -y curl || fail "expected success"
    timeout="$(sed -nE 's/^DPkg::Lock::Timeout "([0-9]+)";$/\1/p' "${APT_CONFIG_LOG}" | head -n1)"
    [ -n "${timeout}" ] || fail "apt was not handed DPkg::Lock::Timeout through APT_CONFIG"
    if [ "${timeout}" -le 590 ] || [ "${timeout}" -gt 600 ]; then
      fail "expected about 600s left, got ${timeout}"
    fi
    ;;

  lock_retry_keeps_the_callers_apt_config)
    APT_CONFIG="${DPKG_ADMINDIR}/caller.conf"
    echo 'Caller::Option "kept";' > "${APT_CONFIG}"
    export APT_CONFIG
    apt_with_dpkg_heal apt-get update || fail "expected success"
    grep -qx 'Caller::Option "kept";' "${APT_CONFIG_LOG}" || fail "the caller's APT_CONFIG was replaced"
    ;;

  # A caller's longer timeout must not stretch one apt run past the budget.
  lock_retry_caps_the_callers_lock_timeout)
    APT_CONFIG="${DPKG_ADMINDIR}/caller.conf"
    printf 'DPkg::Lock::Timeout "3600";\nCaller::Option "kept";\n' > "${APT_CONFIG}"
    export APT_CONFIG
    apt_with_dpkg_heal apt-get update || fail "expected success"
    grep -qx 'Caller::Option "kept";' "${APT_CONFIG_LOG}" || fail "the caller's APT_CONFIG was dropped"
    # apt keeps the last value a file sets, so the budget has to come last.
    timeout="$(sed -nE 's/^DPkg::Lock::Timeout "([0-9]+)";$/\1/p' "${APT_CONFIG_LOG}" | tail -n1)"
    if [ -z "${timeout}" ] || [ "${timeout}" -gt 600 ]; then
      fail "expected the budget to override the caller's 3600s, got '${timeout}'"
    fi
    ;;

  # apt's lock messages are matched in English, so apt must not translate them.
  lock_retry_runs_apt_in_the_c_locale)
    LC_ALL=de_DE.UTF-8 apt_with_dpkg_heal apt-get update || fail "expected success"
    [ "$(cat "${LOCALE_LOG}")" = "C" ] || fail "expected LC_ALL=C, got '$(cat "${LOCALE_LOG}")'"
    ;;

  # The last pause ends at the deadline instead of sleeping a full interval past it.
  lock_retry_cuts_the_last_pause_short)
    LOCK_HELD_ATTEMPTS=1000
    export APT_LOCK_WAIT_SECONDS=2 APT_LOCK_RETRY_INTERVAL_SECONDS=30
    start=$(date +%s)
    status=0
    apt_with_dpkg_heal apt-get update || status=$?
    [ "${status}" = "100" ] || fail "expected apt's exit 100 once the budget is spent, got ${status}"
    [ $(( $(date +%s) - start )) -le 6 ] || fail "slept a full 30s interval past a 2s budget"
    ;;

  lock_retry_rejects_a_malformed_budget)
    export APT_LOCK_WAIT_SECONDS=10m
    status=0
    out="$(apt_lock_retry apt-get update 2>&1)" || status=$?
    [ "${status}" = "2" ] || fail "expected exit 2, got ${status}"
    [[ "${out}" == *"APT_LOCK_WAIT_SECONDS must be whole seconds from 0 to 999999, got '10m'"* ]] \
      || fail "expected the malformed value named, got: ${out}"
    [ "$(attempts)" = "0" ] || fail "apt must not run on a malformed budget; got $(attempts) attempts"
    ;;

  lock_retry_does_not_retry_an_unrelated_failure)
    FORCE_FAIL=true
    status=0
    apt_with_dpkg_heal apt-get update || status=$?
    [ "${status}" = "100" ] || fail "expected exit 100, got ${status}"
    [ "$(attempts)" = "1" ] || fail "only a held lock is retried; got $(attempts) attempts"
    ;;

  # dpkg run directly does not wait for its frontend lock at all.
  repair_waits_for_the_dpkg_lock)
    touch "${DPKG_ADMINDIR}/updates/0001"
    DPKG_LOCK_HELD_ATTEMPTS=1
    apt_with_dpkg_heal apt-get install -y curl || fail "expected the repair to wait out the lock and succeed"
    [ "$(repairs)" = "2" ] || fail "expected the configure to be retried once, got $(repairs)"
    [ "$(attempts)" = "2" ] || fail "expected 2 apt attempts, got $(attempts)"
    ;;

  # The efa failure: the postinst aborts on a stale DKMS tree entry, so
  # `dpkg --configure -a` alone can never succeed. The entry must go first.
  repair_removes_stale_dkms_module)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="efa-3.0.0"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed"
    apt_with_dpkg_heal apt-get upgrade -y || fail "expected recovery to succeed"
    grep -q '^remove efa/3.0.0 --all$' "${DKMS_LOG}" \
      || fail "expected 'dkms remove efa/3.0.0 --all', log: $(cat "${DKMS_LOG}")"
    [ "$(removals)" = "1" ] || fail "expected exactly 1 dkms removal, got $(removals)"
    [ "$(repairs)" = "2" ] || fail "expected configure before and after removal, got $(repairs)"
    [ "$(attempts)" = "2" ] || fail "expected 2 apt attempts, got $(attempts)"
    ;;

  # Module names contain hyphens, so "<module>-<version>" cannot be split on the
  # last hyphen; it has to be resolved against `dkms status`.
  repair_handles_hyphenated_module_name)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="nvidia-peermem-1.2.3"
    FAKE_DKMS_STATUS="nvidia-peermem/1.2.3, 6.17.0-1019-aws, x86_64: installed"
    apt_with_dpkg_heal apt-get upgrade -y || fail "expected recovery to succeed"
    grep -q '^remove nvidia-peermem/1.2.3 --all$' "${DKMS_LOG}" \
      || fail "module/version split wrong, log: $(cat "${DKMS_LOG}")"
    ;;

  # A DKMS conflict with no matching status entry is not repairable; it must
  # surface rather than loop or be reported as success.
  repair_propagates_unresolvable_dkms)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="efa-3.0.0"
    FAKE_DKMS_STATUS=""
    status=0
    apt_with_dpkg_heal apt-get upgrade -y || status=$?
    [ "${status}" = "100" ] || fail "expected the apt exit code to survive, got ${status}"
    [ "$(removals)" = "0" ] || fail "must not remove anything without a match"
    [ "$(attempts)" = "1" ] || fail "must not retry when the repair cannot work"
    ;;

  # A configure failure that is not a DKMS conflict must propagate untouched.
  repair_propagates_non_dkms_configure_failure)
    touch "${DPKG_ADMINDIR}/updates/0001"
    CONFIGURE_FAILS_UNRELATED=true
    status=0
    apt_with_dpkg_heal apt-get update || status=$?
    [ "${status}" = "100" ] || fail "expected the apt exit code to survive, got ${status}"
    [ "$(repairs)" = "1" ] || fail "expected a single repair attempt, got $(repairs)"
    [ "$(attempts)" = "1" ] || fail "must not retry after a failed repair"
    ;;

  # dkms prints one line per kernel and arch, so the same module/version appears
  # repeatedly. That is one entry to remove, not an ambiguous match.
  repair_multi_kernel_entries_removed_once)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="efa-3.0.0"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed
efa/3.0.0, 6.14.0-1018-aws, x86_64: installed
efa/3.0.0, 6.14.0-1018-aws-64k, aarch64: installed"
    apt_with_dpkg_heal apt-get upgrade -y || fail "repeated kernel lines must not block the repair"
    [ "$(removals)" = "1" ] || fail "expected exactly 1 removal, got $(removals)"
    grep -q '^remove efa/3.0.0 --all$' "${DKMS_LOG}" || fail "wrong entry removed: $(cat "${DKMS_LOG}")"
    ;;

  # "<module>-<version>" is lossy: foo-bar/1.2 and foo/bar-1.2 both render to
  # foo-bar-1.2. `dkms remove --all` is destructive, so refuse to guess.
  repair_refuses_ambiguous_dkms_match)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="foo-bar-1.2"
    FAKE_DKMS_STATUS="foo-bar/1.2, 6.17.0-1019-aws, x86_64: installed
foo/bar-1.2, 6.17.0-1019-aws, x86_64: installed"
    status=0
    apt_with_dpkg_heal apt-get upgrade -y || status=$?
    [ "${status}" = "100" ] || fail "expected the apt exit code to survive, got ${status}"
    [ "$(removals)" = "0" ] || fail "must not remove anything when the match is ambiguous"
    [ "$(attempts)" = "1" ] || fail "must not retry when the repair was refused"
    ;;

  # A failed `dkms remove` must not be reported as a successful repair.
  repair_propagates_failed_dkms_remove)
    FAKE_PKG_STATES="half-configured"
    DKMS_CONFLICT="efa-3.0.0"
    FAKE_DKMS_STATUS="efa/3.0.0, 6.17.0-1019-aws, x86_64: installed"
    FAIL_DKMS_REMOVE="true"
    status=0
    apt_with_dpkg_heal apt-get upgrade -y || status=$?
    [ "${status}" = "100" ] || fail "expected the apt exit code to survive, got ${status}"
    [ "$(removals)" = "1" ] || fail "expected the removal to have been attempted"
    [ "$(attempts)" = "1" ] || fail "must not retry after a failed removal"
    # The distinguishing assertion: a swallowed removal failure would fall
    # through to a second `dpkg --configure -a` that cannot possibly work.
    [ "$(repairs)" = "1" ] || fail "must not configure again after a failed removal, got $(repairs)"
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
