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
Tests for the nvidia-setup kernel catalog (skyhook_dir/kernels.conf) and track selection.

kernels.conf is the only file in the package that names a kernel version, one line per
`<flavor> <track> <release> <abi>`. A combination sets KERNEL_FLAVOR= and, per Ubuntu
release, KERNEL_TRACK_<release>= (lts or hwe). A CR overrides the track with the
kernel_track configmap key or NVIDIA_KERNEL_TRACK (env wins). NVIDIA_KERNEL is deprecated:
still honored, with a warning.

The harness sources load_defaults.sh and prints what it resolved; FAKE_CODENAME makes the
container report another Ubuntu release.
"""

import re
from pathlib import Path

import pytest

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
    assert_output_not_contains,
)
from tests.helpers.docker_test import DockerTestRunner

_HERE = Path(__file__).parent
_PACKAGE_DIR = _HERE.parents[2] / "nvidia-setup" / "skyhook_dir"
_HARNESS = (_HERE / "run_load_defaults_test.sh", "skyhook_dir/run_load_defaults_test.sh")
# lts and hwe on noble and resolute, so every selection is observable.
_LTS_HWE = (_HERE / "fixtures" / "kernels-lts-hwe.conf", "skyhook_dir/kernels.conf")
# An older SKU: hwe on noble, lts on resolute.
_H100_BOTH = (
    _HERE / "fixtures" / "eks-h100-lts-on-resolute.conf",
    "skyhook_dir/defaults/eks-h100.conf",
)

_H100 = {"service": "eks", "accelerator": "h100"}
_DEPRECATION = "WARNING: NVIDIA_KERNEL is deprecated"


def _catalog(path: Path) -> dict:
    """(flavor, track, release) -> ABI."""
    entries = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 4 and not fields[0].startswith("#"):
            entries[tuple(fields[:3])] = fields[3]
    return entries


def _resolve(configmaps, env_vars=None, extra=(), codename=None):
    env = dict(env_vars or {})
    if codename:
        env["FAKE_CODENAME"] = codename
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        return runner.run_script(
            script="run_load_defaults_test.sh",
            configmaps=configmaps,
            env_vars=env,
            extra_files=[_HARNESS, *extra],
        )
    finally:
        runner.cleanup()


def _assert_resolved(result, track, kernel):
    assert_exit_code(result, 0)
    assert_output_contains(result.stdout, f"KERNEL_TRACK={track}")
    assert_output_contains(result.stdout, f"KERNEL={kernel}")


# --- Static checks on the shipped catalog and defaults (no container) ---


def test_catalog_lines_are_well_formed():
    """Each line is `<flavor> <lts|hwe> <release> <abi>` under a renovate annotation for that release."""
    lines = (_PACKAGE_DIR / "kernels.conf").read_text().splitlines()
    entries = [(i, l) for i, l in enumerate(lines) if l.strip() and not l.startswith("#")]
    assert entries, "kernels.conf has no kernels"
    for i, line in entries:
        flavor, track, release, abi = line.split()
        assert track in ("lts", "hwe"), line
        assert re.fullmatch(r"[a-z]+", release), line
        assert re.fullmatch(rf"\d+\.\d+\.\d+-\d+-{re.escape(flavor)}", abi), line
        annotation = lines[i - 1]
        assert annotation.startswith("# renovate: datasource=deb "), f"no renovate annotation above: {line}"
        assert f"suite={release}-updates" in annotation, f"annotation is for another release: {line}"
    keys = [tuple(l.split()[:3]) for _, l in entries]
    assert len(keys) == len(set(keys)), "duplicate (flavor, track, release) line"


def test_defaults_name_tracks_not_kernels():
    """No defaults file pins KERNEL=; every track a defaults file names is in the catalog."""
    catalog = _catalog(_PACKAGE_DIR / "kernels.conf")
    for conf in sorted((_PACKAGE_DIR / "defaults").glob("*.conf")):
        text = conf.read_text()
        assert not re.search(r"^KERNEL=", text, re.M), f"{conf.name} pins KERNEL="
        flavor = re.search(r"^KERNEL_FLAVOR=(\S+)$", text, re.M)
        tracks = re.findall(r"^KERNEL_TRACK_([a-z]+)=(\S+)$", text, re.M)
        assert bool(flavor) == bool(tracks), f"{conf.name}: KERNEL_FLAVOR and KERNEL_TRACK_<release> go together"
        for release, track in tracks:
            assert (flavor.group(1), track, release) in catalog, (
                f"{conf.name}: no {flavor.group(1)} {track} {release} line in kernels.conf"
            )


# --- load_defaults.sh resolution ---


@pytest.mark.parametrize("accelerator", ["h100", "gb200", "gb300"])
def test_eks_on_noble_runs_hwe(accelerator):
    expected = _catalog(_PACKAGE_DIR / "kernels.conf")[("aws", "hwe", "noble")]
    result = _resolve({"service": "eks", "accelerator": accelerator})
    _assert_resolved(result, "hwe", expected)
    assert_output_contains(result.stdout, "KERNEL_FLAVOR=aws")
    assert_output_not_contains(result.stdout, _DEPRECATION)


@pytest.mark.parametrize("combination", [("aks", "h100"), ("oci", "any"), ("bcm", "gb200")])
def test_combinations_without_a_flavor_have_no_kernel(combination):
    service, accelerator = combination
    result = _resolve({"service": service, "accelerator": accelerator})
    assert_exit_code(result, 0)
    assert re.search(r"^KERNEL=$", result.stdout, re.M), result.stdout


def test_track_override_on_combination_without_kernel_fails():
    result = _resolve({"service": "aks", "accelerator": "h100", "kernel_track": "hwe"})
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "aks-h100 does not manage the kernel")


@pytest.mark.parametrize(
    "codename,track,kernel",
    [("noble", "hwe", "7.0.0-1014-aws"), ("resolute", "lts", "7.0.0-1020-aws")],
)
def test_sku_track_follows_the_release(codename, track, kernel):
    """One SKU, two releases: hwe on noble, lts on resolute."""
    result = _resolve(_H100, extra=[_LTS_HWE, _H100_BOTH], codename=codename)
    _assert_resolved(result, track, kernel)


def test_configmap_selects_track():
    result = _resolve({**_H100, "kernel_track": "lts\n"}, extra=[_LTS_HWE])
    _assert_resolved(result, "lts", "6.8.0-1040-aws")


def test_env_track_wins_over_configmap():
    result = _resolve(
        {**_H100, "kernel_track": "lts"},
        env_vars={"NVIDIA_KERNEL_TRACK": "hwe"},
        extra=[_LTS_HWE, _H100_BOTH],
        codename="resolute",
    )
    _assert_resolved(result, "hwe", "7.3.0-1005-aws")


def test_release_without_a_track_fails():
    """The catalog has resolute kernels but the shipped eks-h100 names no resolute track: do not guess."""
    result = _resolve(_H100, extra=[_LTS_HWE], codename="resolute")
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "eks-h100 has no kernel track for Ubuntu resolute")
    assert_output_contains(result.stdout, "NVIDIA_KERNEL_TRACK to one of: lts hwe")


@pytest.mark.parametrize("configmaps", [_H100, {**_H100, "kernel_track": "hwe"}], ids=["default", "override"])
def test_release_missing_from_catalog_fails_without_suggesting_an_override(configmaps):
    """The shipped catalog has no resolute line (#196): no track can help, so do not suggest one."""
    result = _resolve(configmaps, codename="resolute")
    assert_exit_code(result, 1)
    assert_output_contains(
        result.stdout, "This nvidia-setup version has no aws kernel for Ubuntu resolute, so eks-h100 is not supported there"
    )
    assert_output_not_contains(result.stdout, "kernel_track")


def test_missing_codename_fails():
    result = _resolve(_H100, codename="none")
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "no usable VERSION_CODENAME")


@pytest.mark.parametrize(
    "configmaps,env_vars",
    [({**_H100, "kernel_track": "aws-7.0"}, {}), (_H100, {"NVIDIA_KERNEL_TRACK": "aws-7.0"})],
    ids=["configmap", "env"],
)
def test_unknown_track_fails(configmaps, env_vars):
    result = _resolve(configmaps, env_vars=env_vars)
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "Unknown kernel track: aws-7.0 (valid: lts, hwe)")


def test_track_missing_from_catalog_lists_available():
    """The shipped catalog has no noble lts line; asking for it fails and says what exists."""
    result = _resolve({**_H100, "kernel_track": "lts"})
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "No aws lts kernel for Ubuntu noble")
    assert_output_contains(result.stdout, "Available for noble: hwe")


@pytest.mark.parametrize("script", ["apply.sh", "apply_check.sh"])
def test_unknown_track_fails_lifecycle_scripts(script):
    runner = DockerTestRunner(package="nvidia-setup")
    try:
        result = runner.run_script(
            script=script,
            configmaps=_H100,
            env_vars={"NVIDIA_KERNEL_TRACK": "nope"},
            skip_system_operations=True,
        )
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "Unknown kernel track: nope")
    finally:
        runner.cleanup()


def test_nvidia_kernel_still_wins_and_warns():
    """Deprecated, not removed: NVIDIA_KERNEL beats any track, even on a release with none."""
    result = _resolve(
        {**_H100, "kernel_track": "lts"},
        env_vars={"NVIDIA_KERNEL": "6.17.0-1019-aws"},
        codename="resolute",
    )
    assert_exit_code(result, 0)
    assert_output_contains(result.stdout, "KERNEL=6.17.0-1019-aws")
    assert_output_contains(result.stdout, _DEPRECATION)


def test_defaults_file_pinning_kernel_is_rejected():
    """A combination that sets KERNEL= directly bypasses the catalog, so the loader refuses it."""
    pinned = (_HERE / "fixtures" / "eks-h100-pins-kernel.conf", "skyhook_dir/defaults/eks-h100.conf")
    result = _resolve(_H100, extra=[pinned])
    assert_exit_code(result, 1)
    assert_output_contains(result.stdout, "sets KERNEL=7.0.0-1014-aws")
