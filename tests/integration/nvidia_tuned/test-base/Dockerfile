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

# Test-only base image: the distro base with `tuned` already installed.
#
# Previously each of the 185 matrix tests in test_prepare_nvidia_profiles.py ran
# `apt-get install tuned` in its own throwaway container (measured 31s each, 19s
# on Rocky). Installing once per OS at image-build time removes that entirely.
#
# Never published; exists only on the machine running the tests.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# hadolint ignore=DL3008,DL3041
RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update -y; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tuned; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y tuned; \
        dnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y tuned; \
        yum clean all; \
    else \
        echo "no supported package manager in this base image" >&2; \
        exit 1; \
    fi; \
    tuned --version
