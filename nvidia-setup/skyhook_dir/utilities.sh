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
# flavor (e.g. 7.0.0-1014-aws), so the only thing left to resolve is the
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

  echo "nvidia-setup: '$*' failed and dpkg is in an interrupted state; repairing and retrying once..." >&2
  dpkg_repair || return "${status}"
  "$@"
}

# Remove the DKMS tree entry that a postinst reported as already present.
# Takes the string dkms prints, "<module>-<version>", and resolves it against
# `dkms status` rather than splitting on the last hyphen, because module names
# contain hyphens too (nvidia-peermem-1.2.3 splits three different ways).
# Returns: 0 when a matching entry was removed, 1 otherwise.
dkms_remove_stale() {
  local target="$1"
  local line ident module version

  if ! command -v dkms >/dev/null 2>&1; then
    echo "nvidia-setup: dkms reported '${target}' but dkms is not installed; cannot repair" >&2
    return 1
  fi

  # Collect every distinct module/version whose "<module>-<version>" matches.
  # dkms prints one line per kernel and arch for the same pair, so the same
  # module/version legitimately appears several times and must be counted once.
  local matches=""
  local match_count=0

  while IFS= read -r line; do
    # `dkms status` lines lead with "<module>/<version>" then ',' or ':'.
    ident="${line%%,*}"
    ident="${ident%%:*}"
    module="${ident%%/*}"
    version="${ident#*/}"
    # module = version means the line had no '/', so it is not a status entry.
    if [ -z "${module}" ] || [ -z "${version}" ] || [ "${module}" = "${version}" ]; then
      continue
    fi

    if [ "${module}-${version}" != "${target}" ]; then
      continue
    fi

    case " ${matches} " in
      *" ${module}/${version} "*) continue ;;
    esac
    matches="${matches} ${module}/${version}"
    match_count=$((match_count + 1))
  done <<DKMS_STATUS
$(dkms status 2>/dev/null)
DKMS_STATUS

  if [ "${match_count}" -eq 0 ]; then
    echo "nvidia-setup: no dkms status entry matches '${target}'; cannot repair" >&2
    return 1
  fi

  # "<module>-<version>" is lossy: foo-bar/1.2 and foo/bar-1.2 both render to
  # foo-bar-1.2. `dkms remove --all` destroys a module across every kernel, so
  # guessing between candidates is not acceptable; refuse and let the failure
  # surface instead.
  if [ "${match_count}" -gt 1 ]; then
    echo "nvidia-setup: '${target}' matches more than one dkms entry (${matches# }); refusing to guess which to remove" >&2
    return 1
  fi

  local entry="${matches# }"
  echo "nvidia-setup: removing stale DKMS module ${entry} so its postinst can re-add it" >&2
  if ! dkms remove "${entry}" --all; then
    echo "nvidia-setup: 'dkms remove ${entry} --all' failed; cannot repair" >&2
    return 1
  fi

  return 0
}

# Repair a dpkg database that apt refused to work with.
#
# `dpkg --configure -a` is enough for an ordinary interrupted state, but not for
# a DKMS package whose postinst aborts with
#   Error! DKMS tree already contains: <module>-<version>
# That postinst fails the same way every time, so the package stays
# half-configured and every later apt command dies on it: repair and retry both
# hit the same wall and the node is wedged until the stale tree entry goes. When
# that is the reported failure, drop the entry and configure once more.
#
# The configure output is captured rather than streamed because it has to be
# parsed for that message. Streaming and capturing at once needs either a
# pipeline (which puts the exit status in a subshell) or process substitution
# (which races the reader), and neither is worth it for a step that is bounded
# by the number of half-configured packages. The long-running apt commands in
# apt_with_dpkg_heal are unaffected and still stream.
# Returns: 0 when the database is usable again.
dpkg_repair() {
  local output
  local status=0

  output="$(dpkg --configure -a 2>&1)" || status=$?
  printf '%s\n' "${output}"

  if [ "${status}" -eq 0 ]; then
    return 0
  fi

  local stale
  stale="$(printf '%s\n' "${output}" \
    | sed -n 's/.*DKMS tree already contains: *\([^[:space:]]*\).*/\1/p' \
    | sort -u)"

  if [ -z "${stale}" ]; then
    return "${status}"
  fi

  local entry
  for entry in ${stale}; do
    dkms_remove_stale "${entry}" || return "${status}"
  done

  dpkg --configure -a
}

# Report whether the EFA driver is genuinely installed.
#
# Leftover traces are not an install. A failed install leaves /opt/amazon/efa
# behind, and libfabric ships in unrelated distro packages, so neither is
# evidence that this package's work succeeded. Treating them as evidence is how
# a node with a half-configured efa reported the step complete. The two signals
# that do mean something:
#
#   1. dpkg has the efa package fully configured. A DKMS postinstall that aborts
#      leaves it half-configured, which is not an install.
#   2. dkms reports the efa kernel module built and installed.
#
# Deliberately does not require the module to be built for the running kernel.
# apply installs EFA before the reboot onto a newly installed kernel, so a
# kernel skew at apply-check time is expected rather than a fault.
# Returns: 0 when EFA is installed, 1 otherwise, with the reason on stderr.
efa_driver_installed() {
  local pkg_state=""

  if command -v dpkg-query >/dev/null 2>&1; then
    pkg_state="$(dpkg-query -W -f '${db:Status-Status}' efa 2>/dev/null || true)"
  fi

  if [ "${pkg_state}" != "installed" ]; then
    echo "EFA: dpkg reports the efa package as '${pkg_state:-absent}', not installed" >&2
    return 1
  fi

  if ! command -v dkms >/dev/null 2>&1; then
    echo "EFA: dkms is not available, so the kernel module cannot be confirmed" >&2
    return 1
  fi

  if ! dkms status efa 2>/dev/null | grep -q 'installed'; then
    echo "EFA: dkms does not report the efa module as installed" >&2
    return 1
  fi

  return 0
}

# Where install-efa-driver.sh records the installer version it last ran. It
# lives outside SKYHOOK_DIR because a new package version gets a fresh one.
efa_installer_record() {
  echo "${NVIDIA_SETUP_STATE_DIR:-/var/lib/nvidia-setup}/efa-installer-version"
}

# Usage: record_efa_installer_version <installer_version>
record_efa_installer_version() {
  local record
  record="$(efa_installer_record)"
  mkdir -p "$(dirname "${record}")"
  printf '%s\n' "$1" > "${record}"
}

# Report whether EFA is installed (efa_driver_installed) and came from the
# configured installer version. An installed EFA is not enough on its own: it
# may be a driver too old for the target kernel. efa 3.0.0 (installer 1.48.0)
# does not compile against the 7.0 aws kernels, and nothing upgrades it while
# installed alone counts as done. A node with no record, such as one set up
# before the record existed, is not current, so it runs the installer once; the
# installer skips any package already at that version or newer.
# Usage: efa_driver_current <installer_version>
# Returns: 0 when current, 1 otherwise, with the reason on stderr.
efa_driver_current() {
  local want="$1"
  local record
  local have=""

  efa_driver_installed || return 1

  record="$(efa_installer_record)"
  if [ -f "${record}" ]; then
    have="$(cat "${record}")"
  fi
  if [ "${have}" != "${want}" ]; then
    echo "EFA: installed from installer '${have:-unrecorded}', configured installer is '${want}'" >&2
    return 1
  fi

  return 0
}

# Report whether dkms has any efa module, in any state. Installing a kernel
# makes dkms build every such module for it, and one that fails to build leaves
# the kernel packages half-configured.
# Returns: 0 when dkms knows an efa module, 1 otherwise.
efa_dkms_registered() {
  local status

  command -v dkms >/dev/null 2>&1 || return 1
  status="$(dkms status efa 2>/dev/null || true)"
  [ -n "${status}" ]
}

# Report whether every named package is fully installed. A package dpkg does not
# know, or one parked half-configured or unpacked, does not count.
# Usage: dpkg_packages_installed <package>...
# Returns: 0 when all are installed, 1 otherwise.
dpkg_packages_installed() {
  local pkg
  local state

  for pkg in "$@"; do
    state="$(dpkg-query -W -f '${db:Status-Status}' "${pkg}" 2>/dev/null || true)"
    if [ "${state}" != "installed" ]; then
      return 1
    fi
  done

  return 0
}

# Report whether apt's package lists carry a real package by this name. Reads
# the local lists only, so it touches neither the network nor the dpkg lock; run
# `apt-get update` first when the answer must reflect the archive as it is now.
# The exit status of `apt-cache show` is not enough on its own: it is 0 for a
# purely virtual package, which has no `Package:` stanza and cannot be installed
# by that name.
# Usage: apt_package_available <package>
# Returns: 0 when the lists have a stanza for it, 1 otherwise.
apt_package_available() {
  local pkg="$1"
  local stanzas

  stanzas="$(apt-cache show "${pkg}" 2>/dev/null)" || return 1
  grep -qx "Package: ${pkg}" <<< "${stanzas}"
}

# The packages that make up kernel <full_kernel_ver>. linux-modules-extra is
# included only when apt's lists carry it: Ubuntu ships it for the 6.17 aws
# kernels but folds those modules into linux-modules for the 7.0 aws kernels,
# and naming a package the archive does not have fails the whole apt install.
# Usage: target_kernel_packages <full_kernel_ver>
# Prints: one package name per line.
target_kernel_packages() {
  local ver="$1"

  printf '%s\n' "linux-image-${ver}" "linux-headers-${ver}" "linux-modules-${ver}"
  if apt_package_available "linux-modules-extra-${ver}"; then
    printf '%s\n' "linux-modules-extra-${ver}"
  fi
}
