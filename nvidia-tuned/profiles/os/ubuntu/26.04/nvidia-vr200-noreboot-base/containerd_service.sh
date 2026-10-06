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

# TuneD script plugin lifecycle: start | stop [full_rollback] | verify [ignore_missing]
# https://github.com/redhat-performance/tuned/blob/v2.21.0/tuned/plugins/plugin_script.py
#
# Raises the stack limit of the container runtime that serves the node's workloads;
# containers inherit it from containerd through their shims. On kubeadm-style nodes that
# runtime is containerd.service. RKE2 and K3s run an embedded containerd as a child of
# their own service instead, so a containerd.service drop-in never reaches it, and a
# distro containerd.service may still be installed but inactive. The drop-in is therefore
# written for every runtime unit installed on the host. Units are selected by whether
# they are installed, not whether they are active, because tuned applies the profile at
# boot, which can be before rke2-server or rke2-agent has started.

set -euo pipefail

DROPIN_FILE=containerd.conf
EXPECTED_LIMIT=67108864
EXPECTED_LINE="LimitSTACK=${EXPECTED_LIMIT}"
# containerd.service first: it stays the target when no runtime unit is installed.
RUNTIME_UNITS=(containerd.service rke2-server.service rke2-agent.service k3s.service k3s-agent.service)

dropin_dir() {
	printf '/etc/systemd/system/%s.d\n' "$1"
}

# K3s names its unit k3s-<name>.service when it is installed with INSTALL_K3S_NAME, so
# that unit is not in RUNTIME_UNITS. List the installed ones from systemd.
named_k3s_units() {
	systemctl list-unit-files --type=service --no-legend 'k3s-*.service' 2>/dev/null \
		| awk '{print $1}' | grep -v -x -F k3s-agent.service || true
}

runtime_units() {
	printf '%s\n' "${RUNTIME_UNITS[@]}"
	named_k3s_units
}

unit_installed() {
	[[ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" == "loaded" ]]
}

# Runtime units to tune. Falls back to containerd.service so a host with none of them
# installed keeps the previous behavior.
target_units() {
	local unit found=false
	while IFS= read -r unit; do
		if unit_installed "${unit}"; then
			printf '%s\n' "${unit}"
			found=true
		fi
	done < <(runtime_units)
	"${found}" || printf '%s\n' containerd.service
}

apply_dropin() {
	local unit dir
	while IFS= read -r unit; do
		dir="$(dropin_dir "${unit}")"
		mkdir -p "${dir}"
		printf '[Service]\n%s\n' "${EXPECTED_LINE}" > "${dir}/${DROPIN_FILE}"
	done < <(target_units)
	systemctl daemon-reload
}

# Removes the drop-in from every runtime unit, installed or not, so nothing is left
# behind if a unit was removed or the runtime changed after start. That includes any
# installer-named K3s unit that has a drop-in directory.
remove_dropin() {
	local unit dir
	local dirs=()
	for unit in "${RUNTIME_UNITS[@]}"; do
		dirs+=("$(dropin_dir "${unit}")")
	done
	for dir in /etc/systemd/system/k3s-*.service.d; do
		if [[ -d "${dir}" ]]; then
			dirs+=("${dir}")
		fi
	done
	for dir in "${dirs[@]}"; do
		rm -f "${dir:?}/${DROPIN_FILE:?}"
		if [[ -d "${dir}" && -z "$(ls -A "${dir}" 2>/dev/null)" ]]; then
			rmdir "${dir}"
		fi
	done
	systemctl daemon-reload
}

# Checks each target unit's drop-in and, for an installed unit, the limit systemd resolves
# for it. The resolved value catches a drop-in that is shadowed by another one or not yet
# loaded. It does not prove the running runtime has the limit: that only changes when the
# runtime restarts, which for these profiles is the reboot that follows tuning.
verify_dropin() {
	local ignore_missing=false
	[[ "${2:-}" == "ignore_missing" ]] && ignore_missing=true
	local unit dir prop value
	while IFS= read -r unit; do
		dir="$(dropin_dir "${unit}")"
		if [[ ! -f "${dir}/${DROPIN_FILE}" ]]; then
			"${ignore_missing}" && continue
			echo "${unit}: ${dir}/${DROPIN_FILE} is missing" >&2
			exit 1
		fi
		if ! grep -q -F -x "${EXPECTED_LINE}" "${dir}/${DROPIN_FILE}"; then
			echo "${unit}: ${dir}/${DROPIN_FILE} does not set ${EXPECTED_LINE}" >&2
			exit 1
		fi
		unit_installed "${unit}" || continue
		for prop in LimitSTACK LimitSTACKSoft; do
			value="$(systemctl show -p "${prop}" --value "${unit}")"
			if [[ "${value}" != "${EXPECTED_LIMIT}" ]]; then
				echo "${unit}: systemd resolves ${prop}=${value}, expected ${EXPECTED_LIMIT}" >&2
				exit 1
			fi
		done
	done < <(target_units)
	exit 0
}

cmd="${1:-}"
case "${cmd}" in
	start)
		apply_dropin
		;;
	stop)
		# TuneD passes full_rollback on a profile switch, `tuned-adm off` or a stop of the
		# daemon, and omits it only when the system is shutting down. The drop-in must
		# survive a reboot: removing it there means the runtime starts without it on the
		# next boot, because tuned rewrites it in parallel with the runtime starting.
		if [[ "${2:-}" == "full_rollback" ]]; then
			remove_dropin
		fi
		;;
	verify)
		verify_dropin "$@"
		;;
	*)
		echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2
		exit 1
		;;
esac
