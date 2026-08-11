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


"""Tests for prebuilt test base image resolution."""

import pytest

from tests.helpers.base_images import (
    assert_image_present,
    baked_tag,
    find_test_base_dockerfile,
    resolve_base_image,
)


def test_tag_is_namespaced_by_package_and_base_image():
    assert baked_tag("nvidia-tuned", "ubuntu:24.04") == (
        "nodewright-test-base:nvidia-tuned-ubuntu-24.04"
    )


def test_tag_is_a_valid_reference_for_namespaced_source_images():
    """A slash in the source image must not create a bogus registry path."""
    assert baked_tag("nvidia-tuned", "rockylinux/rockylinux:9") == (
        "nodewright-test-base:nvidia-tuned-rockylinux-rockylinux-9"
    )


def test_packages_without_a_test_base_dockerfile_use_the_raw_image():
    """Opt-in by file presence: shellscript declares none, so nothing changes."""
    assert find_test_base_dockerfile("shellscript") is None
    assert resolve_base_image("shellscript", "ubuntu:24.04") == "ubuntu:24.04"


def test_missing_prebuilt_image_raises_instead_of_pulling():
    """A missing local image must not silently become a Docker Hub pull."""
    import docker

    class _Images:
        def get(self, tag):
            raise docker.errors.ImageNotFound(tag)

    class _Client:
        images = _Images()

    with pytest.raises(RuntimeError, match="make test-base-images"):
        assert_image_present(_Client(), "nodewright-test-base:nope-0", "nvidia-tuned")


def test_underscore_and_hyphen_package_names_derive_the_same_tag():
    """`make test` iterates tests/integration/ (nvidia_tuned) but the runner
    passes the package dir name (nvidia-tuned). If those derived different tags,
    the built image would never be the one looked up."""
    assert baked_tag("nvidia_tuned", "ubuntu:24.04") == baked_tag(
        "nvidia-tuned", "ubuntu:24.04"
    )
    assert find_test_base_dockerfile("nvidia_tuned") == find_test_base_dockerfile(
        "nvidia-tuned"
    )
