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

# TuneD script plugin lifecycle: start | stop [full_rollback] | verify [ignore_missing]
# https://github.com/redhat-performance/tuned/blob/v2.21.0/tuned/plugins/plugin_script.py

set -e

DROPIN_DIR=/etc/systemd/system/containerd.service.d
DROPIN_FILE=containerd.conf
EXPECTED_LINE='LimitSTACK=67108864'

apply_dropin() {
	mkdir -p "$DROPIN_DIR"
	cat <<EOF > "$DROPIN_DIR/$DROPIN_FILE"
[Service]
LimitSTACK=67108864
EOF
	systemctl daemon-reload
}

remove_dropin() {
	rm -f "$DROPIN_DIR/$DROPIN_FILE"
	if [ -d "$DROPIN_DIR" ] && [ -z "$(ls -A "$DROPIN_DIR" 2>/dev/null)" ]; then
		rmdir "$DROPIN_DIR"
	fi
	systemctl daemon-reload
}

verify_dropin() {
	local ignore_missing=false
	[ "${2:-}" = "ignore_missing" ] && ignore_missing=true

	if [ ! -f "$DROPIN_DIR/$DROPIN_FILE" ]; then
		$ignore_missing && exit 0 || exit 1
	fi
	if [ "$(grep -c -F -x "$EXPECTED_LINE" "$DROPIN_DIR/$DROPIN_FILE")" -lt 1 ]; then
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
