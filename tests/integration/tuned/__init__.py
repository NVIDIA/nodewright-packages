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


# tuned package tests

"""
Test matrix configuration for the tuned package.

The install and uninstall tests install the real tuned package from each
distribution's repositories, so every image here must ship tuned in the
repositories it has configured out of the box.
"""

TEST_MATRIX = [
    "ubuntu:24.04",                          # Noble
    "debian:12",                             # Bookworm
    "registry.suse.com/bci/bci-base:16.0",   # SUSE Linux Enterprise 16.0
    "registry.suse.com/bci/bci-base:15.7",   # SUSE Linux Enterprise 15 SP7
]
