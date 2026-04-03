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

# nvidia-setup package tests

"""
Test matrix configuration for nvidia-setup package.

Define the containers/base images to test against.
Each entry can be a string (base image name) or a dict with additional config.
"""

# Test matrix: list of base images to test against
TEST_MATRIX = [
   # "ubuntu:22.04",  # Jammy - matches current defaults
    # "ubuntu:20.04",  # Focal - if needed
    "ubuntu:24.04",  # Noble - if needed
]

# Alternative: more detailed configuration
# TEST_MATRIX = [
#     {
#         "base_image": "ubuntu:22.04",
#         "name": "jammy",
#         "description": "Ubuntu 22.04 Jammy Jellyfish"
#     },
#     {
#         "base_image": "ubuntu:20.04",
#         "name": "focal",
#         "description": "Ubuntu 20.04 Focal Fossa"
#     },
# ]
