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

# Test harness for the exact-match short circuit in steps/install_kernel.sh.
#
# install_kernel.sh runs as its own process, as ensure_kernel.sh runs it, so the
# stubs are executables on PATH rather than shell functions. uname, apt-get,
# dpkg, dpkg-query, update-grub and grub-set-default are stubbed; every call is
# recorded and the scenario asserts on what was and was not run. dpkg state comes
# from a scratch status file and DPKG_ADMINDIR points at a scratch tree, so the
# real package database is never read. The one real write is /etc/default/grub,
# which only exists inside the throwaway test container.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

set -uo pipefail

SCENARIO="${SCENARIO:?SCENARIO must be set}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
  echo "refusing to run outside a container: this harness rewrites /etc/default/grub" >&2
  exit 1
fi

INSTALL_KERNEL_SH="${SKYHOOK_DIR}/skyhook_dir/steps/install_kernel.sh"
[ -f "${INSTALL_KERNEL_SH}" ] || { echo "install_kernel.sh not found at ${INSTALL_KERNEL_SH}" >&2; exit 1; }

# The base kernel from the eks defaults; resolve_full_kernel adds -64k on arm64.
KERNEL="6.17.0-1019-aws"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
STUB_BIN="${WORK_DIR}/bin"
DPKG_ADMINDIR="${WORK_DIR}/dpkg"
STATUS_FILE="${WORK_DIR}/status"
CALL_LOG="${WORK_DIR}/calls.log"
OUTPUT="${WORK_DIR}/output.log"
mkdir -p "${STUB_BIN}" "${DPKG_ADMINDIR}/updates"
: > "${STATUS_FILE}"
: > "${CALL_LOG}"
export DPKG_ADMINDIR STATUS_FILE CALL_LOG

# STATUS_FILE holds one "<package> <dpkg status>" line per package dpkg knows.

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) echo "${FAKE_UNAME_R}" ;;
  -m) echo "${FAKE_UNAME_M}" ;;
  *)  echo "Linux" ;;
esac
EOF

# Real apt refuses to run while any package is parked mid-transaction. A
# successful install records its packages, so the `dpkg --list` that follows
# sees them.
cat > "${STUB_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "${CALL_LOG}"
if awk '$2 ~ /^(half-installed|unpacked|half-configured)$/ { found = 1 } END { exit !found }' "${STATUS_FILE}"; then
  echo "E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem." >&2
  exit 100
fi
if [ "${1:-}" = "install" ]; then
  shift
  for arg in "$@"; do
    case "${arg}" in
      -*) ;;
      *) echo "${arg} installed" >> "${STATUS_FILE}" ;;
    esac
  done
fi
exit 0
EOF

# `dpkg --configure -a` fails the way it did on the aicr#2870 nodes: the EFA
# DKMS build cannot compile against the half-configured 7.0.0 kernel.
cat > "${STUB_BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
echo "dpkg $*" >> "${CALL_LOG}"
case "${1:-}" in
  --list)
    awk '$1 ~ /^linux-image-/ { print "ii  " $1 }' "${STATUS_FILE}"
    ;;
  --configure)
    if awk '$2 ~ /^(half-installed|unpacked|half-configured)$/ { found = 1 } END { exit !found }' "${STATUS_FILE}"; then
      echo "kcompat.h:274: error: 'struct ib_umem' has no member named 'nmap'" >&2
      echo "dpkg: error processing package linux-image-7.0.0-1012-aws (--configure)" >&2
      exit 1
    fi
    ;;
esac
exit 0
EOF

# Handles both call shapes in utilities.sh: `-W -f FMT <pkg>...` for named
# packages and `-f FMT -W` for every package.
cat > "${STUB_BIN}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
echo "dpkg-query $*" >> "${CALL_LOG}"
pkgs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W|--show) ;;
    -f|--showformat) shift ;;
    *) pkgs+=("$1") ;;
  esac
  shift
done
if [ "${#pkgs[@]}" -eq 0 ]; then
  awk '{ print $2 }' "${STATUS_FILE}"
  exit 0
fi
rc=0
for pkg in "${pkgs[@]}"; do
  state="$(awk -v p="${pkg}" '$1 == p { print $2 }' "${STATUS_FILE}")"
  if [ -z "${state}" ]; then
    echo "dpkg-query: no packages found matching ${pkg}" >&2
    rc=1
  else
    printf '%s' "${state}"
  fi
done
exit "${rc}"
EOF

for cmd in update-grub grub-set-default; do
  cat > "${STUB_BIN}/${cmd}" <<EOF
#!/usr/bin/env bash
echo "${cmd} \$*" >> "\${CALL_LOG}"
exit 0
EOF
done

chmod +x "${STUB_BIN}"/*

mkdir -p /etc/default
echo "GRUB_DEFAULT=0" > /etc/default/grub

fail() {
  echo "FAIL (${SCENARIO}): $*" >&2
  echo "--- install_kernel.sh output ---" >&2
  cat "${OUTPUT}" >&2
  echo "--- calls ---" >&2
  cat "${CALL_LOG}" >&2
  exit 1
}

# node <arch> <running kernel>
node() {
  export FAKE_UNAME_M="$1" FAKE_UNAME_R="$2"
}

# package_state <state> <package>...
package_state() {
  local state="$1" pkg
  shift
  for pkg in "$@"; do
    echo "${pkg} ${state}" >> "${STATUS_FILE}"
  done
}

kernel_packages() {
  local ver="$1"
  echo "linux-image-${ver}" "linux-headers-${ver}" "linux-modules-${ver}" "linux-modules-extra-${ver}"
}

run_install_kernel() {
  PATH="${STUB_BIN}:${PATH}" "${INSTALL_KERNEL_SH}" "${KERNEL}" > "${OUTPUT}" 2>&1
}

apt_ran() { grep -q '^apt-get ' "${CALL_LOG}"; }

installed_packages_for() {
  local ver="$1" pkg
  for pkg in $(kernel_packages "${ver}"); do
    grep -qE "^apt-get .*install .*\\b${pkg}( |$)" "${CALL_LOG}" \
      || fail "apt-get install should include ${pkg}"
  done
}

case "${SCENARIO}" in
  # The node already booted the target and has every package apt would install,
  # so apt has nothing to do and must not be run.
  skips_apt_on_target)
    node x86_64 "6.17.0-1019-aws"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    apt_ran && fail "apt must not run when the target kernel is running and installed"
    ;;

  # arm64 targets the -64k flavor, so that is what must be running.
  skips_apt_on_target_arm64)
    node aarch64 "6.17.0-1019-aws-64k"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    apt_ran && fail "apt must not run when the target kernel is running and installed"
    ;;

  # aicr#2870: a node on the target kernel carried unrelated dpkg damage from an
  # unattended-upgrades kernel whose EFA DKMS build could not compile. The
  # redundant apt call inherited that damage and failed the step.
  succeeds_on_target_despite_unrelated_dpkg_damage)
    node aarch64 "6.17.0-1019-aws-64k"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws-64k")
    package_state half-configured linux-image-7.0.0-1012-aws linux-headers-7.0.0-1012-aws
    package_state unpacked linux-aws linux-headers-aws
    run_install_kernel || fail "install_kernel.sh must not fail on damage it has no need to touch"
    apt_ran && fail "apt must not run when the target kernel is running and installed"
    grep -q '^dpkg --configure' "${CALL_LOG}" && fail "dpkg --configure must not run"
    ;;

  # Skipping apt must not skip pinning GRUB to the target: that is what keeps a
  # later kernel install (e.g. unattended-upgrades) from becoming the boot default.
  keeps_grub_default_when_skipping)
    node x86_64 "6.17.0-1019-aws"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    grep -qx 'grub-set-default Advanced options for Ubuntu>Ubuntu, with Linux 6.17.0-1019-aws' "${CALL_LOG}" \
      || fail "GRUB default must still be set to the target kernel"
    grep -qx 'GRUB_DEFAULT=saved' /etc/default/grub || fail "GRUB_DEFAULT must be 'saved'"
    ;;

  installs_when_running_other_kernel)
    node x86_64 "6.8.0-1015-aws"
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws"
    ;;

  # Running the target is not enough on its own: nvidia-setup-full builds EFA
  # with DKMS, which needs the headers this step installs.
  installs_when_target_package_missing)
    node x86_64 "6.17.0-1019-aws"
    package_state installed linux-image-6.17.0-1019-aws linux-modules-6.17.0-1019-aws \
      linux-modules-extra-6.17.0-1019-aws
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws"
    ;;

  # Same upstream version and ABI, wrong page-size flavor: comparing only the
  # upstream version would call this a match and leave the node on 4k pages.
  installs_when_arm64_runs_4k_flavor)
    node aarch64 "6.17.0-1019-aws"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws-64k"
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
