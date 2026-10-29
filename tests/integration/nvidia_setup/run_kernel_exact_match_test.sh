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
# apt-cache, dpkg, dpkg-query, dkms, curl, tar, update-grub and grub-set-default
# are stubbed; every call is recorded and the scenario asserts on what was and
# was not run. dpkg state comes from a scratch status file and DPKG_ADMINDIR
# points at a scratch tree, so the real package database is never read. What the
# archive offers, and what dkms knows, come from further scratch files. The
# stubbed tar unpacks a fake EFA installer, so the real install-efa-driver.sh
# runs without downloading anything. The one real write is /etc/default/grub,
# which only exists inside the throwaway test container.
#
# Exit code 0 = the scenario behaved as specified, 1 = it did not.

set -euo pipefail

SCENARIO="${SCENARIO:?SCENARIO must be set}"
[ -n "${SKYHOOK_DIR:-}" ] || { echo "SKYHOOK_DIR must be set" >&2; exit 1; }
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
  echo "refusing to run outside a container: this harness rewrites /etc/default/grub" >&2
  exit 1
fi

INSTALL_KERNEL_SH="${SKYHOOK_DIR}/skyhook_dir/steps/install_kernel.sh"
[ -f "${INSTALL_KERNEL_SH}" ] || { echo "install_kernel.sh not found at ${INSTALL_KERNEL_SH}" >&2; exit 1; }

# The base kernel; resolve_full_kernel adds -64k on arm64. No eks default names a
# 6.17 kernel since 0.9.0, but NVIDIA_KERNEL still can, and its archive ships
# modules-extra as its own package. The 7.0 scenarios set KERNEL themselves.
KERNEL="6.17.0-1019-aws"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
STUB_BIN="${WORK_DIR}/bin"
DPKG_ADMINDIR="${WORK_DIR}/dpkg"
STATUS_FILE="${WORK_DIR}/status"
ARCHIVE_FILE="${WORK_DIR}/archive"
DKMS_FILE="${WORK_DIR}/dkms"
CALL_LOG="${WORK_DIR}/calls.log"
OUTPUT="${WORK_DIR}/output.log"
mkdir -p "${STUB_BIN}" "${DPKG_ADMINDIR}/updates"
: > "${STATUS_FILE}"
: > "${ARCHIVE_FILE}"
: > "${DKMS_FILE}"
: > "${CALL_LOG}"
export DPKG_ADMINDIR STATUS_FILE ARCHIVE_FILE DKMS_FILE CALL_LOG

# STATUS_FILE holds one "<package> <dpkg status>" line per package dpkg knows.
# ARCHIVE_FILE holds one package name per line for each package apt can install.
# DKMS_FILE is what `dkms status efa` prints.

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) echo "${FAKE_UNAME_R}" ;;
  -m) echo "${FAKE_UNAME_M}" ;;
  *)  echo "Linux" ;;
esac
EOF

# Real apt refuses to run while any package is parked mid-transaction, and
# installs nothing when one requested package is not in the archive. A
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
  pkgs=()
  for arg in "$@"; do
    case "${arg}" in
      -*) ;;
      *)
        if ! grep -qx "${arg}" "${ARCHIVE_FILE}"; then
          echo "E: Unable to locate package ${arg}" >&2
          exit 100
        fi
        pkgs+=("${arg}")
        ;;
    esac
  done
  for pkg in "${pkgs[@]}"; do
    echo "${pkg} installed" >> "${STATUS_FILE}"
  done
fi
exit 0
EOF

# Answers from ARCHIVE_FILE the way `apt-cache show` answers from apt's lists:
# a stanza per known package, and exit 100 when it knows none of them.
cat > "${STUB_BIN}/apt-cache" <<'EOF'
#!/usr/bin/env bash
echo "apt-cache $*" >> "${CALL_LOG}"
[ "${1:-}" = "show" ] || exit 0
shift
found=false
for pkg in "$@"; do
  if grep -qx "${pkg}" "${ARCHIVE_FILE}"; then
    printf 'Package: %s\nVersion: 0-stub\n\n' "${pkg}"
    found=true
  fi
done
if [ "${found}" != "true" ]; then
  echo "E: No packages found" >&2
  exit 100
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
# packages and `-f FMT -W` for every package. A package recorded more than once
# reports its latest state, as an upgrade leaves it.
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
  state="$(awk -v p="${pkg}" '$1 == p { s = $2 } END { print s }' "${STATUS_FILE}")"
  if [ -z "${state}" ]; then
    echo "dpkg-query: no packages found matching ${pkg}" >&2
    rc=1
  else
    printf '%s' "${state}"
  fi
done
exit "${rc}"
EOF

cat > "${STUB_BIN}/dkms" <<'EOF'
#!/usr/bin/env bash
echo "dkms $*" >> "${CALL_LOG}"
[ "${1:-}" = "status" ] && cat "${DKMS_FILE}"
exit 0
EOF

# Fetches nothing: the tar stub below supplies the installer.
cat > "${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${CALL_LOG}"
exit 0
EOF

# Unpacks a fake EFA installer into the current directory. It upgrades efa the
# way the real one does, or fails as a broken install would when
# FAKE_EFA_INSTALLER_FAILS=true.
cat > "${STUB_BIN}/tar" <<'EOF'
#!/usr/bin/env bash
echo "tar $*" >> "${CALL_LOG}"
mkdir -p aws-efa-installer
cat > aws-efa-installer/efa_installer.sh <<'INSTALLER'
#!/usr/bin/env bash
echo "efa_installer.sh $*" >> "${CALL_LOG}"
if [ "${FAKE_EFA_INSTALLER_FAILS:-false}" = "true" ]; then
  echo "Error: Failed to install packages." >&2
  exit 1
fi
echo "efa installed" >> "${STATUS_FILE}"
echo "efa/3.3.1, $(uname -r), $(uname -m): installed" > "${DKMS_FILE}"
INSTALLER
chmod +x aws-efa-installer/efa_installer.sh
exit 0
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

# archive <package>...
archive() {
  printf '%s\n' "$@" >> "${ARCHIVE_FILE}"
}

# The 6.17 aws kernels ship modules-extra as its own package.
kernel_packages() {
  local ver="$1"
  echo "linux-image-${ver}" "linux-headers-${ver}" "linux-modules-${ver}" "linux-modules-extra-${ver}"
}

# The 7.0 aws kernels fold modules-extra into linux-modules.
folded_kernel_packages() {
  local ver="$1"
  echo "linux-image-${ver}" "linux-headers-${ver}" "linux-modules-${ver}"
}

# In the scratch tree, since the EFA step unpacks its installer into the
# working directory.
run_install_kernel() {
  (cd "${WORK_DIR}" && PATH="${STUB_BIN}:${PATH}" "${INSTALL_KERNEL_SH}" "${KERNEL}") > "${OUTPUT}" 2>&1
}

# A GB node as nvidia-setup 0.8.x left it: on 6.17 with efa 3.0.0 from
# installer 1.48.0.
gb_node_with_efa_3_0() {
  KERNEL="7.0.0-1014-aws"
  export EFA="1.51.0" EFA_DRIVER="3.3.1"
  node aarch64 "6.17.0-1019-aws-64k"
  # shellcheck disable=SC2046
  archive $(folded_kernel_packages "7.0.0-1014-aws-64k")
  package_state installed efa
  echo "efa/3.0.0, 6.17.0-1019-aws-64k, aarch64: installed" > "${DKMS_FILE}"
}

# The same for an H100 node, which installs the flavor as-is.
h100_node_with_efa_3_0() {
  KERNEL="7.0.0-1014-aws"
  export EFA="1.51.0" EFA_DRIVER="3.3.1"
  node x86_64 "6.17.0-1019-aws"
  # shellcheck disable=SC2046
  archive $(folded_kernel_packages "7.0.0-1014-aws")
  package_state installed efa
  echo "efa/3.0.0, 6.17.0-1019-aws, x86_64: installed" > "${DKMS_FILE}"
}

efa_installer_ran() { grep -q '^efa_installer.sh ' "${CALL_LOG}"; }

# The line number of the first CALL_LOG entry matching <regex>, or nothing.
first_call() { grep -nE "$1" "${CALL_LOG}" | head -n1 | cut -d: -f1; }

apt_ran() { grep -q '^apt-get ' "${CALL_LOG}"; }

# assert_install_requested <package>...
assert_install_requested() {
  local pkg
  for pkg in "$@"; do
    grep -qE "^apt-get .*install .*\\b${pkg}( |$)" "${CALL_LOG}" \
      || fail "apt-get install should include ${pkg}"
  done
}

installed_packages_for() {
  # shellcheck disable=SC2046
  assert_install_requested $(kernel_packages "$1")
}

# Every scenario's archive carries the 6.17 targets; scenarios add the rest.
# shellcheck disable=SC2046
archive $(kernel_packages "6.17.0-1019-aws") $(kernel_packages "6.17.0-1019-aws-64k")

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

  # Same upstream version, different ABI. check_kernel_exact would call these
  # equal. The target packages are installed, so only the kernel comparison can
  # tell the two apart.
  installs_when_abi_differs)
    node x86_64 "6.17.0-1018-aws"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws"
    ;;

  # A newer kernel is not the target either: the pin is exact, not a floor. The
  # target packages are installed, so only the kernel comparison can tell.
  installs_when_running_newer_kernel)
    node x86_64 "7.0.0-1012-aws"
    # shellcheck disable=SC2046
    package_state installed $(kernel_packages "6.17.0-1019-aws")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws"
    ;;

  # The archive has no linux-modules-extra for the 7.0 aws kernels. Naming it
  # anyway fails the whole install, so the target installs without it.
  installs_target_without_modules_extra)
    KERNEL="7.0.0-1014-aws"
    node aarch64 "6.17.0-1019-aws-64k"
    # shellcheck disable=SC2046
    archive $(folded_kernel_packages "7.0.0-1014-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    # shellcheck disable=SC2046
    assert_install_requested $(folded_kernel_packages "7.0.0-1014-aws-64k")
    grep -qE '^apt-get .*install .*linux-modules-extra-' "${CALL_LOG}" \
      && fail "apt-get must not be asked for a linux-modules-extra the archive does not have"
    ;;

  # A 7.0 node on its target has every package the archive offers for it, so the
  # missing modules-extra must not count against the short circuit.
  skips_apt_on_target_without_modules_extra)
    KERNEL="7.0.0-1014-aws"
    node aarch64 "7.0.0-1014-aws-64k"
    # shellcheck disable=SC2046
    archive $(folded_kernel_packages "7.0.0-1014-aws-64k")
    # shellcheck disable=SC2046
    package_state installed $(folded_kernel_packages "7.0.0-1014-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    apt_ran && fail "apt must not run when the target kernel is running and installed"
    ;;

  # Where the archive does ship modules-extra it is still part of the target, so
  # a node missing only that package is not on target.
  installs_when_only_modules_extra_missing)
    node x86_64 "6.17.0-1019-aws"
    package_state installed linux-image-6.17.0-1019-aws linux-headers-6.17.0-1019-aws \
      linux-modules-6.17.0-1019-aws
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    installed_packages_for "6.17.0-1019-aws"
    ;;

  # aicr#2870: dkms builds efa 3.0.0 for the new kernel and it does not compile
  # against 7.0, leaving the kernel half-configured. EFA has to move first.
  upgrades_stale_efa_before_installing_kernel)
    gb_node_with_efa_3_0
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    efa_installer_ran || fail "an efa module older than the configured driver must be upgraded"
    efa_line="$(first_call '^efa_installer\.sh ')"
    kernel_line="$(first_call '^apt-get .*install .*linux-image-7\.0\.0-1014-aws-64k')"
    [ -n "${kernel_line}" ] || fail "the kernel must still be installed"
    [ "${efa_line}" -lt "${kernel_line}" ] || fail "EFA must be upgraded before the kernel is installed"
    ;;

  # eks-h100 is on 7.0 too: the same order, the 4k flavor, no modules-extra.
  upgrades_stale_efa_before_installing_kernel_x86)
    h100_node_with_efa_3_0
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    efa_installer_ran || fail "an efa module older than the configured driver must be upgraded"
    efa_line="$(first_call '^efa_installer\.sh ')"
    kernel_line="$(first_call '^apt-get .*install .*linux-image-7\.0\.0-1014-aws( |$)')"
    [ -n "${kernel_line}" ] || fail "the kernel must still be installed"
    [ "${efa_line}" -lt "${kernel_line}" ] || fail "EFA must be upgraded before the kernel is installed"
    # shellcheck disable=SC2046
    assert_install_requested $(folded_kernel_packages "7.0.0-1014-aws")
    grep -qE '^apt-get .*install .*linux-modules-extra-' "${CALL_LOG}" \
      && fail "apt-get must not be asked for a linux-modules-extra the archive does not have"
    ;;

  installs_kernel_without_reinstalling_current_efa)
    gb_node_with_efa_3_0
    echo "efa/3.3.1, 6.17.0-1019-aws-64k, aarch64: installed" > "${DKMS_FILE}"
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    efa_installer_ran && fail "an efa module at the configured driver must not be reinstalled"
    # shellcheck disable=SC2046
    assert_install_requested $(folded_kernel_packages "7.0.0-1014-aws-64k")
    ;;

  # A fresh node: no efa module for dkms to rebuild, and the full setup installs
  # EFA after the reboot.
  installs_kernel_without_efa_on_node_without_efa)
    KERNEL="7.0.0-1014-aws"
    export EFA="1.51.0" EFA_DRIVER="3.3.1"
    node aarch64 "6.17.0-1019-aws-64k"
    # shellcheck disable=SC2046
    archive $(folded_kernel_packages "7.0.0-1014-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    grep -qE '^(curl|efa_installer\.sh) ' "${CALL_LOG}" && fail "no efa module means no EFA step"
    # shellcheck disable=SC2046
    assert_install_requested $(folded_kernel_packages "7.0.0-1014-aws-64k")
    ;;

  # The short circuit stays free of network and package-manager work, EFA
  # included.
  skips_efa_and_apt_on_target)
    gb_node_with_efa_3_0
    node aarch64 "7.0.0-1014-aws-64k"
    # shellcheck disable=SC2046
    package_state installed $(folded_kernel_packages "7.0.0-1014-aws-64k")
    run_install_kernel || fail "install_kernel.sh exited non-zero"
    apt_ran && fail "apt must not run when the target kernel is running and installed"
    grep -qE '^(curl|efa_installer\.sh) ' "${CALL_LOG}" && fail "EFA must not be touched on the target kernel"
    ;;

  # Installing the kernel over an EFA that cannot build for it is the failure
  # the upgrade exists to prevent, so a failed upgrade stops the step there.
  efa_upgrade_failure_stops_kernel_install)
    gb_node_with_efa_3_0
    export FAKE_EFA_INSTALLER_FAILS=true
    run_install_kernel && fail "a failed EFA upgrade must fail the step"
    grep -qE '^apt-get .*install .*linux-image-' "${CALL_LOG}" \
      && fail "the kernel must not be installed after the EFA upgrade failed"
    ;;

  *)
    echo "unknown SCENARIO: ${SCENARIO}" >&2
    exit 1
    ;;
esac

echo "ok (${SCENARIO})"
exit 0
