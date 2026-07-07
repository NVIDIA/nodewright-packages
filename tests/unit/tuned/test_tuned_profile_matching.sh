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

# Dependency-free unit test for tuned_list_has_profile in tuned/skyhook_dir/utils.sh.
# Runs with plain bash; needs no Docker and no installed tuned.
#
#   bash tests/unit/tuned/test_tuned_profile_matching.sh
#
# Regression guard for the bug where `tuned-adm list` drops the padding space
# before the "- <summary>" column once a profile name is long enough, so a name
# anchored match (`^- <name>$`) failed for every summary-bearing profile
# (e.g. nvidia-gb200-multiNodeTraining).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS="${SCRIPT_DIR}/../../../tuned/skyhook_dir/utils.sh"
# shellcheck source=/dev/null
source "${UTILS}"

# Verbatim `tuned-adm list` output captured from the failing run. Note the two
# multiNodeTraining lines: the 30/29-char names butt directly against the
# "- <summary>" column with no separating space.
read -r -d '' TUNED_ADM_LIST <<'EOF'
Available profiles:
- accelerator
- balanced                     - General non-specialized tuned profile
- hpc-compute                  - Optimize for HPC compute workloads
- intent
- nvidia-acs-disable           - Disable acs for pci
- nvidia-base                  - Base NVIDIA tuning configuration
- nvidia-gb200-inference       - Optimized for inference workloads
- nvidia-gb200-multiNodeTraining- Optimized for multi-node distributed training
- nvidia-gb200-performance     - TuneD Profile for DGX GB200
- nvidia-generic               - NVIDIA Generic GPU Profile
- nvidia-h100-inference        - Optimized for inference workloads
- nvidia-h100-multiNodeTraining- Optimized for multi-node distributed training
- nvidia-h100-performance      - NVIDIA H100 Performance Profile
Current active profile: balanced
EOF

failures=0

# assert_present <profile>: matcher must find it (exit 0)
assert_present() {
    if printf '%s\n' "${TUNED_ADM_LIST}" | tuned_list_has_profile "$1"; then
        echo "ok: found '$1'"
    else
        echo "FAIL: expected to find profile '$1' but it was reported missing"
        failures=$((failures + 1))
    fi
}

# assert_absent <profile>: matcher must NOT find it (exit non-zero)
assert_absent() {
    if printf '%s\n' "${TUNED_ADM_LIST}" | tuned_list_has_profile "$1"; then
        echo "FAIL: did not expect to find profile '$1' but it matched"
        failures=$((failures + 1))
    else
        echo "ok: correctly absent '$1'"
    fi
}

# The regression: long, summary-bearing names with no padding space.
assert_present "nvidia-gb200-multiNodeTraining"
assert_present "nvidia-h100-multiNodeTraining"

# Summary-bearing names that ARE padded (also broke under the old `$` anchor).
assert_present "nvidia-gb200-inference"
assert_present "nvidia-base"
assert_present "balanced"

# Summary-less names (the only case the old anchor handled).
assert_present "accelerator"
assert_present "intent"

# A name that is a prefix of others must not false-match the longer profiles.
assert_absent "nvidia-gb200"
assert_absent "nvidia-gb200-multiNode"
assert_absent "does-not-exist"

if [[ "${failures}" -ne 0 ]]; then
    echo "FAILED: ${failures} assertion(s)"
    exit 1
fi
echo "PASSED: all assertions"
