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

# nvidia-tuned package tests

"""
Test matrix configuration for nvidia-tuned package.

Define the containers/base images to test against.
Each entry can be a string (base image name) or a dict with additional config.
"""

# Test matrix: list of base images to test against
TEST_MATRIX = [
    "ubuntu:24.04",  # Noble
    "ubuntu:22.04",  # Jammy
    "debian:12",     # Bookworm
    "rockylinux:9",  # Rocky Linux 9
]
