#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# TuneD script plugin: start | stop | verify
# OKE: Ubuntu GRUB integration + optional cx8 pci=config_acs drop-in (see NVIDIA_TUNED_OKE_NETWORK).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CX8_ACS_GRUB="/etc/default/grub.d/99-nvidia-tuned-oke-cx8-acs.cfg"

oke_network_mode() {
	local n="${NVIDIA_TUNED_OKE_NETWORK:-cx7}"
	echo "$n" | tr '[:upper:]' '[:lower:]']
}

is_ubuntu() {
	[ -f /etc/os-release ] || return 1
	# shellcheck source=/dev/null
	. /etc/os-release
	[ "${ID:-}" = "ubuntu" ]
}

run_bootloader() {
	if [ -f "${SCRIPT_DIR}/bootloader.sh" ]; then
		"${SCRIPT_DIR}/bootloader.sh"
	fi
}

apply_cx8_acs_grub() {
	local mode
	mode="$(oke_network_mode)"
	if [ "$mode" != "cx8" ]; then
		return 0
	fi
	if ! is_ubuntu; then
		echo "OKE cx8 pci=config_acs drop-in is Ubuntu-only; skipping on this OS."
		return 0
	fi
	if [ "${NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS:-}" = "true" ] || [ "${NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS:-}" = "1" ]; then
		echo "NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS set; skipping cx8 ACS grub fragment."
		return 0
	fi
	local src="${SCRIPT_DIR}/cx8-pci-config-acs.grub"
	if [ ! -f "$src" ]; then
		echo "WARNING: cx8 ACS template missing: $src"
		return 0
	fi
	mkdir -p "$(dirname "$CX8_ACS_GRUB")"
	cp -f "$src" "$CX8_ACS_GRUB"
	chmod 0644 "$CX8_ACS_GRUB"
	if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
		echo "apply_cx8_acs_grub: SKIP_SYSTEM_OPERATIONS set; skipping update-grub"
	else
		if ! command -v update-grub >/dev/null 2>&1; then
			echo "apply_cx8_acs_grub: update-grub not found in PATH" >&2
			exit 1
		fi
		update-grub
	fi
}

remove_cx8_acs_grub() {
	rm -f "$CX8_ACS_GRUB"
	if is_ubuntu; then
		if [ -n "${SKIP_SYSTEM_OPERATIONS:-}" ]; then
			:
		else
			if ! command -v update-grub >/dev/null 2>&1; then
				echo "remove_cx8_acs_grub: update-grub not found in PATH" >&2
				exit 1
			fi
			update-grub
		fi
	fi
}

verify_cx8_acs_grub() {
	local ignore_missing=false
	[ "${2:-}" = "ignore_missing" ] && ignore_missing=true
	local mode
	mode="$(oke_network_mode)"
	if [ "$mode" != "cx8" ]; then
		exit 0
	fi
	if ! is_ubuntu; then
		exit 0
	fi
	if [ "${NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS:-}" = "true" ] || [ "${NVIDIA_TUNED_OKE_SKIP_PCI_CONFIG_ACS:-}" = "1" ]; then
		exit 0
	fi
	if [ ! -f "$CX8_ACS_GRUB" ]; then
		if $ignore_missing; then
			exit 0
		fi
		echo "Expected cx8 ACS grub fragment missing: $CX8_ACS_GRUB"
		exit 1
	fi
	exit 0
}

cmd="${1:-}"
case "$cmd" in
	start)
		run_bootloader
		apply_cx8_acs_grub
		;;
	stop)
		remove_cx8_acs_grub
		;;
	verify)
		verify_cx8_acs_grub "$@"
		;;
	*)
		echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2
		exit 1
		;;
esac
