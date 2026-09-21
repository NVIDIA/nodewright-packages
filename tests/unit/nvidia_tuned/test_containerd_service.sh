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

# Dependency-free regression test for the nvidia-tuned containerd drop-in script.
#
#   bash tests/unit/nvidia_tuned/test_containerd_service.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../../../nvidia-tuned/profiles/os/common/nvidia-gb200-performance/containerd_service.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/state"
cp "${SCRIPT_DIR}/../../integration/nvidia_tuned/fakes/systemctl" "${TEST_ROOT}/bin/systemctl"
chmod +x "${TEST_ROOT}/bin/systemctl"

run_script() {
	SYSTEMD_SYSTEM_UNIT_DIR="${TEST_ROOT}/systemd" \
	FAKE_SYSTEMCTL_STATE="${TEST_ROOT}/state" \
	PATH="${TEST_ROOT}/bin:${PATH}" \
		bash "${SCRIPT}" "$@"
}

agent_dropin="${TEST_ROOT}/systemd/rke2-agent.service.d/containerd.conf"
containerd_dropin="${TEST_ROOT}/systemd/containerd.service.d/containerd.conf"

# An active RKE2 agent must receive the drop-in, not the inactive distro unit.
touch "${TEST_ROOT}/state/active.rke2-agent.service"
run_script start
[[ -f "${agent_dropin}" ]]
[[ ! -e "${containerd_dropin}" ]]
run_script verify

# Verification must reject an inert containerd drop-in when RKE2 owns the runtime.
rm -f "${agent_dropin}"
mkdir -p "$(dirname "${containerd_dropin}")"
printf '[Service]\nLimitSTACK=67108864\n' > "${containerd_dropin}"
if run_script verify; then
	echo "FAIL: verification accepted an inactive containerd drop-in"
	exit 1
fi

# With no RKE2 unit active, retain the standalone containerd fallback.
rm -f "${TEST_ROOT}/state/active.rke2-agent.service" "${containerd_dropin}"
touch "${TEST_ROOT}/state/active.containerd.service"
run_script start
[[ -f "${containerd_dropin}" ]]
run_script verify

# Teardown removes drop-ins from every supported target, including stale targets.
mkdir -p "${TEST_ROOT}/systemd/rke2-server.service.d"
printf '[Service]\nLimitSTACK=67108864\n' \
	> "${TEST_ROOT}/systemd/rke2-server.service.d/containerd.conf"
run_script stop
[[ ! -e "${agent_dropin}" ]]
[[ ! -e "${containerd_dropin}" ]]
[[ ! -e "${TEST_ROOT}/systemd/rke2-server.service.d/containerd.conf" ]]

echo "PASSED: containerd drop-in selects and verifies the active runtime unit"
