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

# Makes the active profile's [bootloader] cmdline reach the booted kernel on Ubuntu.
#
# tuned writes the resolved [bootloader] stanza to /etc/tuned/bootcmdline as
# TUNED_BOOT_CMDLINE, then rewrites /etc/default/grub itself. Ubuntu assembles
# GRUB_CMDLINE_LINUX_DEFAULT from /etc/default/grub.d/ instead, so on Ubuntu that rewrite
# is ignored and the profile's cmdline silently never applies. This step writes a
# /etc/default/grub.d/ drop-in that sources tuned's file, then regenerates grub.
#
# DEBIAN-FAMILY ONLY. Sourcing /etc/default/grub.d/*.cfg is a Debian/Ubuntu patch to
# grub-mkconfig. RHEL-family grub2-mkconfig reads /etc/default/grub and /etc/grub.d/ and
# ignores that directory entirely, so the drop-in would be written, grub would regenerate
# happily, and the arguments would never reach the kernel. The package as a whole falls
# back to os/common profiles on untested distributions, so this step cannot assume the
# OS gate happened upstream and checks for itself. It fails rather than skipping quietly:
# a node that reports success while running none of the tuning it was selected for is the
# worse outcome. Set CONFIGURE_BOOTLOADER=false to opt out deliberately.
#
# Gated on ${SKYHOOK_DIR}/profiles/service/${service}/bootloader.enabled, so services
# without the marker are a no-op. The marker is service-wide rather than per-accelerator:
# every accelerator reached through such a service wants its cmdline on the host.
#
# Runs after the config step that applies the profile, because /etc/tuned/bootcmdline
# only exists once tuned has activated it.
#
# Lands on the kernel command line, so it needs `interrupt: {type: reboot}`.

set -euo pipefail

CONFIGMAP_DIR="${SKYHOOK_DIR}/configmaps"
PROFILES_DIR="${SKYHOOK_DIR}/profiles"

# Overridable so tests can point at a stub.
TUNED_GRUB_DROPIN="${TUNED_GRUB_DROPIN:-/etc/default/grub.d/99-nvidia-tuned-cmdline.cfg}"
TUNED_BOOTCMDLINE="${TUNED_BOOTCMDLINE:-/etc/tuned/bootcmdline}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"

# Identifies a drop-in this package owns. The eks and aks services write their own
# grub.d file from inside the tuned profile; scoping removal to our marker keeps this
# step from deleting theirs when it stands down on a node running one of them.
DROPIN_MARKER="Managed by the nvidia-tuned Skyhook package (configure_bootloader.sh)"

# 99- sorts after every numbered producer, so this assignment is evaluated last and its
# arguments win where a token is set twice.
#
# Appends to GRUB_CMDLINE_LINUX_DEFAULT rather than replacing it, which is where this
# differs from the older in-profile script the eks and aks services use. Replacing it
# drops whatever the platform put there, which on a bare-metal host includes the serial
# console arguments an operator needs to reach a node that fails to come up.
#
# Deliberately a different filename from that script's 99_tuned.cfg: the two must be able
# to coexist on a node that has switched services, and this step must never remove a file
# it did not write.
#
# Unquoted heredoc: ${TUNED_BOOTCMDLINE} is baked in now, the escaped names stay literal
# for grub to expand at config-generation time.
DROPIN_CONTENT="$(cat <<EOF
# ${DROPIN_MARKER}. Do not edit.
#
# Sources the cmdline tuned resolved from the active profile's [bootloader] stanza.
# Without this, a profile's [bootloader] settings never reach the kernel on Ubuntu.
if [ -f ${TUNED_BOOTCMDLINE} ]; then
    . ${TUNED_BOOTCMDLINE}
    GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} \${TUNED_BOOT_CMDLINE}"
fi
EOF
)"

# Returns 0 when the drop-in exists and this package wrote it.
dropin_is_ours() {
    [[ -f "${TUNED_GRUB_DROPIN}" ]] && grep -qF "${DROPIN_MARKER}" "${TUNED_GRUB_DROPIN}"
}

# Returns 0 unless CONFIGURE_BOOTLOADER switches the step off.
bootloader_requested() {
    local setting
    setting="$(printf '%s' "${CONFIGURE_BOOTLOADER:-true}" | tr '[:upper:]' '[:lower:]')"
    case "${setting}" in
        false | 0 | no | off) return 1 ;;
        *) return 0 ;;
    esac
}

# Returns 0 when the configured service opts in.
bootloader_enabled() {
    local service

    [[ -f "${CONFIGMAP_DIR}/service" ]] || return 1
    service="$(xargs < "${CONFIGMAP_DIR}/service")"
    [[ -n "${service}" ]] || return 1

    [[ -f "${PROFILES_DIR}/service/${service}/bootloader.enabled" ]]
}

# Returns 0 on a distribution whose grub-mkconfig sources /etc/default/grub.d/*.cfg.
#
# Checks ID and ID_LIKE so Debian derivatives that do carry the patch (Pop, Mint, and the
# vendor Ubuntu rebuilds these nodes run) are recognised without an explicit allowlist.
bootloader_os_supported() {
    local ids

    [[ -r "${OS_RELEASE}" ]] || return 1
    # set +u inside the subshell: os-release is a fragment, not a script of ours.
    ids="$(
        set +u
        # shellcheck source=/dev/null
        . "${OS_RELEASE}" 2>/dev/null
        printf '%s %s' "${ID:-}" "${ID_LIKE:-}"
    )"

    case " ${ids} " in
        *" debian "* | *" ubuntu "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Reports the distribution for error messages.
os_pretty_name() {
    (
        set +u
        # shellcheck source=/dev/null
        . "${OS_RELEASE}" 2>/dev/null
        printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"
    )
}

# Debian-family only, so update-grub is the mechanism. No grub2-mkconfig fallback: it
# would regenerate a RHEL-family grub.cfg that ignores the drop-in, turning an
# unsupported platform into a silent no-op instead of a visible failure.
regenerate_grub() {
    if [[ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]]; then
        echo "SKIP_SYSTEM_OPERATIONS set: not regenerating the bootloader config"
        return 0
    fi

    if ! command -v update-grub >/dev/null 2>&1; then
        echo "ERROR: update-grub is not available, so the drop-in cannot be applied."
        echo "  This step supports GRUB on Debian-family distributions. A node booting"
        echo "  through something else (systemd-boot, a UKI) needs CONFIGURE_BOOTLOADER=false"
        echo "  and its kernel arguments set by whatever owns them."
        return 1
    fi

    update-grub
}

# Drop a drop-in this package previously wrote. Called when the service gate stops
# matching, so a custom resource switched from rke2 to a no-reboot service does not keep
# contributing the old cmdline on every future boot with no package owning it.
remove_dropin() {
    dropin_is_ours || return 0

    local backup
    backup="$(mktemp)"
    cp "${TUNED_GRUB_DROPIN}" "${backup}"
    rm -f "${TUNED_GRUB_DROPIN}"

    if ! regenerate_grub; then
        mv "${backup}" "${TUNED_GRUB_DROPIN}"
        echo "ERROR: could not regenerate the bootloader config; restored ${TUNED_GRUB_DROPIN}"
        exit 1
    fi

    rm -f "${backup}"
    echo "Removed ${TUNED_GRUB_DROPIN}; a reboot is required to drop the profile cmdline"
}

# The only place an operator will look, so name the cause and both ways forward.
fail_unsupported_os() {
    cat <<EOF
ERROR: This node's distribution does not support the bootloader mechanism this step uses.

  Detected: $(os_pretty_name)

  The step writes ${TUNED_GRUB_DROPIN} and relies on grub-mkconfig sourcing
  /etc/default/grub.d/*.cfg, which is a Debian/Ubuntu patch. RHEL-family grub2-mkconfig
  reads /etc/default/grub and /etc/grub.d/ and ignores that directory, so the drop-in
  would be written, GRUB would regenerate without error, and none of the profile's kernel
  arguments would reach the booted kernel.

  This fails rather than passing quietly because the alternative is a node that reports
  success while running none of the tuning it was selected for.

  Either:
    - use a service that does not carry [bootloader] tuning (bcm re-roots the same
      accelerators onto a bootloader-free profile chain), or
    - set CONFIGURE_BOOTLOADER=false in the package env on the custom resource to skip
      this step and its checks, and set the kernel arguments by another route.
EOF
    exit 1
}

main() {
    if ! bootloader_requested; then
        echo "Bootloader step switched off via CONFIGURE_BOOTLOADER; nothing to configure"
        return 0
    fi

    if ! bootloader_enabled; then
        echo "Bootloader drop-in not enabled for this service; nothing to configure"
        remove_dropin
        return 0
    fi

    # After the service gate, so an unsupported distribution running a service that never
    # wanted a drop-in is not failed for it.
    if ! bootloader_os_supported; then
        fail_unsupported_os
    fi

    # Not fatal. The drop-in guards on the file, so it starts contributing as soon as
    # tuned writes one, and a profile chain carrying no [bootloader] stanza legitimately
    # produces no bootcmdline at all. configure_bootloader_check.sh reports the mismatch.
    if [[ ! -f "${TUNED_BOOTCMDLINE}" ]]; then
        echo "WARNING: ${TUNED_BOOTCMDLINE} does not exist; the active profile chain resolved no [bootloader] settings"
    fi

    # Deliberately no "content already current, skipping" short-circuit. The drop-in is
    # static but the file it sources is not: changing intent rewrites
    # /etc/tuned/bootcmdline while leaving this file byte-identical, and grub only picks
    # the new value up when it is regenerated. Skipping on unchanged content would leave
    # the node booting the previous intent's cmdline.
    local backup=""
    if [[ -f "${TUNED_GRUB_DROPIN}" ]]; then
        backup="$(mktemp)"
        cp "${TUNED_GRUB_DROPIN}" "${backup}"
    fi

    mkdir -p "$(dirname "${TUNED_GRUB_DROPIN}")"
    printf '%s\n' "${DROPIN_CONTENT}" > "${TUNED_GRUB_DROPIN}"

    if ! regenerate_grub; then
        if [[ -n "${backup}" ]]; then
            mv "${backup}" "${TUNED_GRUB_DROPIN}"
            echo "ERROR: could not regenerate the bootloader config; restored the previous ${TUNED_GRUB_DROPIN}"
        else
            rm -f "${TUNED_GRUB_DROPIN}"
            echo "ERROR: could not regenerate the bootloader config; removed ${TUNED_GRUB_DROPIN}"
        fi
        exit 1
    fi

    if [[ -n "${backup}" ]]; then
        rm -f "${backup}"
    fi

    echo "Wrote ${TUNED_GRUB_DROPIN}; a reboot is required for the profile cmdline to take effect"
}

main "$@"
