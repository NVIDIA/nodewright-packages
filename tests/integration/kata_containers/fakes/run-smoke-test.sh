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

set -euo pipefail
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' \
    -keyout /tmp/smoke-key.pem -out /tmp/smoke-cert.pem >/dev/null 2>&1
scenario="${CASE:-success}"
if [[ "$scenario" == signal ]]; then export CASE=timeout; fi
python3 /skyhook-package/test-api.py &
api_pid=$!
trap 'kill "$api_pid" 2>/dev/null || true' EXIT
for _ in {1..100}; do
    if [[ -f /tmp/kata-api-ready ]]; then break; fi
    sleep 0.05
done
mkdir -p /tmp/smoke-work
export NODE_NAME=test-node SKYHOOK_RESOURCE_ID=test-resource
export KATA_SMOKE_API_HOST=127.0.0.1 KATA_SMOKE_API_PORT=8443
KATA_SMOKE_CA="$(cat /tmp/smoke-cert.pem)"
export KATA_SMOKE_CA
export KATA_SMOKE_TOKEN=REPLACE_ME
export KATA_SMOKE_WORK_DIR=/tmp/smoke-work
export KATA_SMOKE_TIMEOUT=5 KATA_SMOKE_CLEANUP_TIMEOUT=2
if [[ "$scenario" == timeout ]]; then export KATA_SMOKE_TIMEOUT=2; fi
if [[ "$scenario" == signal ]]; then
    export CASE=timeout KATA_SMOKE_TIMEOUT=30
    # Deliver TERM from inside the pending helper. This also works on hosts
    # whose stacked AppArmor profiles deny signals between test processes.
    sleep() { kill -TERM "$BASHPID"; }
    export -f sleep
    /bin/bash /skyhook-package/skyhook_dir/smoke.sh
else
    /skyhook-package/skyhook_dir/smoke.sh
fi
