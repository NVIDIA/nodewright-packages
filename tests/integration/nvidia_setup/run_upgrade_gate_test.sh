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

# Test harness for the NVIDIA_SETUP_APT_UPGRADE gate in steps/upgrade.sh.
#
# apt-get, dpkg and dpkg-query are stubbed and DPKG_ADMINDIR points at a clean
# scratch tree, so upgrade.sh runs end to end without touching the system. Every
# apt invocation is recorded and the scenario asserts on what was and was not run.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

set -uo pipefail

SCENARIO="${SCENARIO:?SCENARIO must be set}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }

UPGRADE_SH="${SKYHOOK_DIR}/skyhook_dir/steps/upgrade.sh"
[ -f "${UPGRADE_SH}" ] || { echo "upgrade.sh not found at ${UPGRADE_SH}" >&2; exit 1; }

DPKG_ADMINDIR="$(mktemp -d)"
export DPKG_ADMINDIR
mkdir -p "${DPKG_ADMINDIR}/updates"
APT_LOG="${DPKG_ADMINDIR}/apt.log"
: > "${APT_LOG}"
trap 'rm -rf "${DPKG_ADMINDIR}"' EXIT

# Record every apt invocation; never actually do anything.
apt-get() { echo "apt-get $*" >> "${APT_LOG}"; return 0; }
# A healthy dpkg, so the heal path stays out of the way.
dpkg-query() { printf 'installed\n'; }
dpkg() { return 0; }

fail() { echo "FAIL (${SCENARIO}): $*" >&2; exit 1; }

ran()     { grep -q "^apt-get .*\\b$1\\b" "${APT_LOG}"; }
upgraded(){ grep -qE "^apt-get .* upgrade( |$)" "${APT_LOG}"; }

run_upgrade_sh() {
  # shellcheck source=../../../nvidia-setup/skyhook_dir/steps/upgrade.sh
  . "${UPGRADE_SH}"
}

case "${SCENARIO}" in
  # The default. A blanket upgrade can restart containerd and kill the pod
  # running this very step, so it must not happen unless asked for.
  upgrade_skipped_by_default)
    unset NVIDIA_SETUP_APT_UPGRADE || true
    run_upgrade_sh > /dev/null 2>&1 || fail "upgrade.sh exited non-zero"
    upgraded && fail "apt-get upgrade must not run by default. log: $(cat "${APT_LOG}")"
    ran update  || fail "apt-get update should still run"
    ran install || fail "the targeted install should still run"
    ;;

  upgrade_runs_when_enabled)
    export NVIDIA_SETUP_APT_UPGRADE=true
    run_upgrade_sh > /dev/null 2>&1 || fail "upgrade.sh exited non-zero"
    upgraded || fail "apt-get upgrade should run when opted in. log: $(cat "${APT_LOG}")"
    ;;

  upgrade_skipped_when_false)
    export NVIDIA_SETUP_APT_UPGRADE=false
    run_upgrade_sh > /dev/null 2>&1 || fail "upgrade.sh exited non-zero"
    upgraded && fail "explicit false must skip the upgrade"
    ;;

  # Only the exact string "true" opts in; a near-miss must stay off rather
  # than being read as truthy.
  upgrade_skipped_on_non_true_value)
    export NVIDIA_SETUP_APT_UPGRADE=yes
    run_upgrade_sh > /dev/null 2>&1 || fail "upgrade.sh exited non-zero"
    upgraded && fail "'yes' must not opt in; only 'true' does"
    ;;

  # The tooling install is what later steps depend on, so the gate must not
  # take it out along with the blanket upgrade.
  install_still_runs_when_upgrade_skipped)
    unset NVIDIA_SETUP_APT_UPGRADE || true
    run_upgrade_sh > /dev/null 2>&1 || fail "upgrade.sh exited non-zero"
    for pkg in curl git wget gpg; do
      grep -q "install .*${pkg}" "${APT_LOG}" || fail "${pkg} should still be installed"
    done
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
