#!/usr/bin/env python3

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

"""
A version bump runs the upgrade stage, never apply, so upgrade must do what
apply does.

When a package's version rises on a node that completed the old one, the
operator runs upgrade, config and the interrupt. Before 0.9.0 nvidia-setup
declared no upgrade mode, so the agent ran nothing and reported success: a node
moved off 0.8.x kept its old kernel and EFA.
"""

import json
from pathlib import Path

import pytest


PACKAGE = Path(__file__).resolve().parents[3] / "nvidia-setup"


def _steps(mode):
    """The mode's steps, minus the name, which only labels the step."""
    modes = json.loads((PACKAGE / "config.json").read_text())["modes"]
    return [{k: v for k, v in step.items() if k != "name"} for step in modes[mode]]


@pytest.mark.parametrize(
    "upgrade_mode, apply_mode",
    [("upgrade", "apply"), ("upgrade-check", "apply-check")],
)
def test_upgrade_runs_what_apply_runs(upgrade_mode, apply_mode):
    assert _steps(upgrade_mode) == _steps(apply_mode)
