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

set -euo pipefail

SYSTEMD_SYSTEM_UNIT_DIR="${SYSTEMD_SYSTEM_UNIT_DIR:-/etc/systemd/system}"
DROPIN_FILE=containerd.conf
EXPECTED_LINE='LimitSTACK=67108864'

runtime_unit() {
	local unit
	for unit in rke2-server.service rke2-agent.service; do
		if systemctl is-active --quiet "${unit}" >/dev/null; then
			printf '%s\n' "${unit}"
			return 0
		fi
	done
	printf '%s\n' 'containerd.service'
}

dropin_dir() {
	printf '%s/%s.d\n' "${SYSTEMD_SYSTEM_UNIT_DIR}" "$(runtime_unit)"
}

all_dropin_dirs() {
	printf '%s\n' \
		"${SYSTEMD_SYSTEM_UNIT_DIR}/rke2-server.service.d" \
		"${SYSTEMD_SYSTEM_UNIT_DIR}/rke2-agent.service.d" \
		"${SYSTEMD_SYSTEM_UNIT_DIR}/containerd.service.d"
}

apply_dropin() {
	local target_dir
	target_dir="$(dropin_dir)"
	mkdir -p "${target_dir}"
	cat <<EOF > "${target_dir}/${DROPIN_FILE}"
[Service]
LimitSTACK=67108864
EOF
	systemctl daemon-reload
}

remove_dropin() {
	local target_dir
	while IFS= read -r target_dir; do
		rm -f "${target_dir}/${DROPIN_FILE}"
		if [[ -d "${target_dir}" && -z "$(ls -A "${target_dir}" 2>/dev/null)" ]]; then
			rmdir "${target_dir}"
		fi
	done < <(all_dropin_dirs)
	systemctl daemon-reload
}

verify_dropin() {
	local ignore_missing=false
	local target_dir
	[[ "${2:-}" == "ignore_missing" ]] && ignore_missing=true
	target_dir="$(dropin_dir)"

	if [[ ! -f "${target_dir}/${DROPIN_FILE}" ]]; then
		${ignore_missing} && exit 0 || exit 1
	fi
	if [[ "$(grep -c -F -x "${EXPECTED_LINE}" "${target_dir}/${DROPIN_FILE}")" -lt 1 ]]; then
		exit 1
	fi
	exit 0
}

cmd="${1:-}"
case "$cmd" in
	start)
		apply_dropin
		;;
	stop)
		remove_dropin
		# full_rollback (arg 2) - same unapply for this script
		;;
	verify)
		verify_dropin "$@"
		;;
	*)
		echo "Usage: $0 start | stop [full_rollback] | verify [ignore_missing]" >&2
		exit 1
		;;
esac
