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
Tests for the shared Docker test harness itself.

These cover the per-container lifecycle costs that every package's tests pay, so
a regression here silently slows down the entire suite.
"""

import time

import docker
import pytest

from tests.helpers.docker_test import DockerTestRunner

BASE_IMAGE = "ubuntu:24.04"


def _detached_container(runner: DockerTestRunner, **kwargs):
    """Start the same kind of keep-alive container the harness itself uses."""
    return runner.client.containers.run(
        BASE_IMAGE,
        command=["/bin/bash", "-c", "tail -f /dev/null"],
        detach=True,
        **kwargs,
    )


def test_cleanup_removes_container_promptly():
    """Teardown must SIGKILL immediately rather than wait out a graceful stop.

    Our containers run `tail -f /dev/null` as PID 1. The kernel ignores
    default-disposition SIGTERM for PID 1, so a graceful `stop()` blocks for its
    full timeout on every single test before the SIGKILL lands. These containers
    are throwaway and hold no state worth flushing, so SIGKILL is correct.
    """
    runner = DockerTestRunner(package="shellscript", base_image=BASE_IMAGE)
    runner.container = _detached_container(runner)
    container_id = runner.container.id

    start = time.monotonic()
    runner.cleanup()
    elapsed = time.monotonic() - start

    # Measured: 0.21s with force-remove, 5.25s with the old graceful stop.
    # 3.0s sits far from both, so this asserts behavior without being timing-flaky.
    assert elapsed < 3.0, f"cleanup took {elapsed:.2f}s; expected a prompt SIGKILL"

    with pytest.raises(docker.errors.NotFound):
        runner.client.containers.get(container_id)
