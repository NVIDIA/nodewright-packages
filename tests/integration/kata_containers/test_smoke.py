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

"""Exercise create, verification, deletion and failure handling over a TLS API."""

import json
from pathlib import Path

import pytest
import yaml

from tests.helpers.docker_test import DockerTestRunner


HERE = Path(__file__).parent
FILES = [(HERE / "fakes/run-smoke-test.sh", "skyhook_dir/test-smoke.sh"),
         (HERE / "fakes/kube-api.py", "test-api.py")]


@pytest.mark.parametrize("case,passed", [
    ("success", True), ("transient", True), ("lost-response", True), ("stale", True),
    ("failed", False), ("timeout", False), ("wrong-exit", False), ("signal", False),
    ("forbidden", False), ("foreign", False), ("delete-forbidden", False),
    ("delete-stuck", False), ("uid-conflict", False),
])
def test_smoke_pod_lifecycle_over_tls(base_image, case, passed):
    with DockerTestRunner(package="kata-containers", base_image=base_image) as runner:
        result = runner.run_script(script="test-smoke.sh", env_vars={"CASE": case}, extra_files=FILES)
        assert (result.exit_code == 0) is passed, result.stdout
        trace = runner.container.exec_run(["cat", "/tmp/kata-api-trace"])
        calls = [json.loads(line) for line in trace.output.decode().splitlines()]
        creates = [call for call in calls if call["method"] == "POST"]
        deletes = [call for call in calls if call["method"] == "DELETE"]
        if case in ("foreign", "forbidden"):
            assert not creates and not deletes
        else:
            assert creates and deletes
            pod = creates[0]["body"]
            assert pod["spec"]["nodeName"] == "test-node"
            assert pod["spec"]["runtimeClassName"] == "kata-containers-qemu-nvidia-cpu-runtime-rs"
            assert pod["spec"]["restartPolicy"] == "Never"
            assert pod["spec"]["automountServiceAccountToken"] is False
            assert pod["spec"]["containers"][0]["command"] == ["/bin/uname", "-r"]
            assert pod["spec"]["containers"][0]["securityContext"]["capabilities"]["drop"] == ["ALL"]
            assert all(call["body"].get("preconditions", {}).get("uid") for call in deletes)
        if passed:
            assert calls[-1]["method"] == "GET"
            assert "succeeded on test-node and was deleted" in result.stdout
        assert "REPLACE_ME" not in result.stdout
        assert runner.container.exec_run(["bash", "-c", "test -z \"$(ls -A /tmp/smoke-work)\""]).exit_code == 0


def test_smoke_rbac_is_limited_to_an_isolated_namespace():
    package = HERE.resolve().parents[2] / "kata-containers"
    resources = list(yaml.safe_load_all((package / "smoke-rbac.yaml").read_text()))
    assert not any(item["kind"] in ("ClusterRole", "ClusterRoleBinding") for item in resources)
    role = next(item for item in resources if item["kind"] == "Role")
    assert role["metadata"]["namespace"] == "kata-containers-smoke"
    assert role["rules"] == [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "create", "delete"]}]
    account = next(item for item in resources if item["kind"] == "ServiceAccount")
    assert account["automountServiceAccountToken"] is False
