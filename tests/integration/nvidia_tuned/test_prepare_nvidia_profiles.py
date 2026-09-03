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
Tests for nvidia-tuned prepare_nvidia_profiles.sh script.

Tests verify:
- Tuned version meets OS-specific requirements (>= 2.15 for Ubuntu 22.04/Debian 11, >= 2.19 for others)
- prepare_nvidia_profiles does the right thing for all combinations of:
  - accelerator (h100, gb200, generic)
  - intent (performance, inference, multiNodeTraining)
  - service (eks, aks, bcm, rke2, none)
- accelerator=generic uses self-contained nvidia-generic profile, ignoring intent and service
- For AWS service, verifies grub config file is created correctly
- For the rke2 service, verifies the [bootloader] chain survives and the grub.d drop-in,
  its checks, and its teardown behave
"""

import pytest
import re

from pathlib import Path

from tests.helpers.assertions import (
    assert_exit_code,
    assert_output_contains,
)
from tests.helpers.docker_test import DockerTestRunner


# The prepare scripts source utils.sh, which in production comes from the parent
# tuned image. The test harness copies only the on-disk nvidia-tuned/ dir into a
# raw base image, so inject the parent utils.sh explicitly.
_REPO_ROOT = Path(__file__).resolve().parents[3]
UTILS_SRC = _REPO_ROOT / "tuned" / "skyhook_dir" / "utils.sh"
UTILS_DEST = "skyhook_dir/utils.sh"


def _matches_any(text: str, *patterns: str) -> bool:
    """Check if any of the patterns are contained in the text."""
    return any(pattern in text for pattern in patterns)


def _get_tuned_major_minor(runner: DockerTestRunner) -> tuple[int, int]:
    """Parse the container's installed tuned version into (major, minor)."""
    if runner.container is None:
        raise RuntimeError("Container not initialized. Call create_container_for_testing first.")
    result = runner.container.exec_run(["tuned", "--version"], workdir="/")
    assert_exit_code(result, 0)
    output = result.output.decode("utf-8", errors="replace")
    m = re.search(r"tuned\s+(\d+)\.(\d+)", output)
    assert m is not None, f"Could not parse tuned version from: {output}"
    return int(m.group(1)), int(m.group(2))


def verify_tuned_version(runner: DockerTestRunner, base_image: str):
    """Verify tuned version meets OS-specific requirement."""
    # Determine required version based on OS
    
    match base_image:
        # These don't have the calc_iso_cpus function in their profile so only need 2.15
        case img if _matches_any(img, "ubuntu:22.04", "debian:11"):
            # OS versions requiring tuned >= 2.15
            required_major, required_minor = (2, 15)
        case img if _matches_any(img, "ubuntu:24.04", "ubuntu:26.04", "debian:12", "rocky:9", "rockylinux:9"):
            # OS versions requiring tuned >= 2.19
            required_major, required_minor = (2, 19)
        case _:
            # Default to 2.19 for unknown OS
            required_major, required_minor = (2, 19)
    
    major, minor = _get_tuned_major_minor(runner)

    assert major > required_major or (major == required_major and minor >= required_minor), \
        f"tuned version {major}.{minor} is less than required {required_major}.{required_minor} for {base_image}"


def expected_profiles_dir(runner: DockerTestRunner) -> str:
    """Return the dir tuned reads profiles from, based on the container's version.

    tuned >= 2.23.0 -> /etc/tuned/profiles ; older -> /etc/tuned.
    Mirrors resolve_tuned_profiles_dir in tuned/skyhook_dir/utils.sh.
    """
    major, minor = _get_tuned_major_minor(runner)
    if major > 2 or (major == 2 and minor >= 23):
        return "/etc/tuned/profiles"
    return "/etc/tuned"


def create_container_for_testing(runner: DockerTestRunner, configmaps: dict):
    """Create a container for testing without running scripts."""
    import tempfile
    import shutil
    from pathlib import Path
    
    # Use the same approach as run_script but don't execute the script
    # Set up package environment
    temp_dir = tempfile.mkdtemp(prefix="skyhook-test-")
    runner.temp_dir = temp_dir
    skyhook_package_dir = Path(temp_dir) / "skyhook-package"
    
    # Copy entire package directory structure
    shutil.copytree(runner._package_path, skyhook_package_dir, dirs_exist_ok=True)

    # Inject the parent tuned utils.sh (sourced by the prepare scripts).
    utils_dest = skyhook_package_dir / "skyhook_dir" / "utils.sh"
    utils_dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(UTILS_SRC, utils_dest)
    utils_dest.chmod(0o755)

    # Create configmaps directory and write configmaps
    configmaps_dir = skyhook_package_dir / "configmaps"
    configmaps_dir.mkdir(parents=True, exist_ok=True)
    
    if configmaps:
        for key, value in configmaps.items():
            configmap_file = configmaps_dir / key
            configmap_file.write_text(value)
    
    # Create node-metadata directory
    node_metadata_dir = skyhook_package_dir / "node-metadata"
    node_metadata_dir.mkdir(parents=True, exist_ok=True)
    
    # Set up environment variables
    container_env = {
        "SKYHOOK_DIR": "/skyhook-package",
        "STEP_ROOT": "/skyhook-package/skyhook_dir",
    }
    
    # Create container with bind mount
    runner.container = runner.client.containers.run(
        runner.base_image,
        command=["/bin/bash", "-c", "tail -f /dev/null"],  # Keep container running
        detach=True,
        environment=container_env,
        volumes={
            str(skyhook_package_dir): {
                "bind": "/skyhook-package",
                "mode": "rw"
            }
        },
        remove=False,
        tty=False,
        stdin_open=False
    )
    
    # Wait for container to be ready
    runner.wait_until_ready()


def run_script_in_container(runner: DockerTestRunner, script: str, configmaps: dict):
    """Run a script in an existing container with given configmaps."""
    if runner.container is None:
        raise RuntimeError("Container must exist before running script")
    
    # Update configmaps in the container
    configmap_cmds = []
    for key, value in configmaps.items():
        # Escape single quotes in values
        escaped_value = value.replace("'", "'\"'\"'")
        configmap_cmds.append(f"echo '{escaped_value}' > /skyhook-package/configmaps/{key}")
    
    runner.container.exec_run(
        ["bash", "-c", f"mkdir -p /skyhook-package/configmaps && {' && '.join(configmap_cmds)}"],
        workdir="/"
    )
    
    # Run the script in the existing container
    script_path = f"/skyhook-package/skyhook_dir/{script}"
    container_env = {
        "SKYHOOK_DIR": "/skyhook-package",
        "STEP_ROOT": "/skyhook-package/skyhook_dir",
        "SKIP_SYSTEM_OPERATIONS": "true",
    }
    
    cmd = f"bash {script_path} 2>&1"
    exec_result = runner.container.exec_run(
        ["/bin/bash", "-c", cmd],
        workdir="/skyhook-package",
        environment=container_env
    )
    
    # Create a TestResult-like object
    class TestResult:
        def __init__(self, exit_code, stdout, stderr=""):
            self.exit_code = exit_code
            self.stdout = stdout
            self.stderr = stderr
    
    return TestResult(
        exec_result.exit_code,
        exec_result.output.decode('utf-8', errors='replace'),
        ""
    )


def test_tuned_version_requirement(base_image):
    """Test that tuned version meets OS-specific requirement (>= 2.15 for Ubuntu 22.04/Debian 11, >= 2.19 for others)."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        # Create container directly
        create_container_for_testing(runner, {"accelerator": "h100"})
        verify_tuned_version(runner, base_image)
    finally:
        runner.cleanup()


@pytest.mark.parametrize("accelerator", ["h100", "gb200"])
@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_no_service(base_image, accelerator, intent):
    """Test prepare_nvidia_profiles with all accelerator/intent combinations without service."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": accelerator,
            "intent": intent,
        }
        
        # Create container directly (faster than running script first)
        create_container_for_testing(runner, configmaps)
        
        
        # Now run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        
        # Verify profile name is constructed correctly
        expected_profile = f"nvidia-{accelerator}-{intent}"
        assert_output_contains(result.stdout, expected_profile)
        
        # Verify profile was written to configmap
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert expected_profile in tuned_profile_content, \
            f"Expected profile {expected_profile} not found in tuned_profile file"
        
        # Verify profile directory exists in the version-resolved profiles dir
        profiles_dir = expected_profiles_dir(runner)
        profile_exists = runner.file_exists(f"{profiles_dir}/{expected_profile}/tuned.conf")
        assert profile_exists, \
            f"Profile {expected_profile} was not deployed to {profiles_dir}/"
        
    finally:
        runner.cleanup()


@pytest.mark.parametrize("accelerator", ["h100", "gb200"])
@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_with_eks_service(base_image, accelerator, intent):
    """Test prepare_nvidia_profiles with EKS service for all combinations."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": accelerator,
            "intent": intent,
            "service": "eks",
        }
        
        # Create container by running script (this creates the container)
        try:
            runner.run_script(
                script="prepare_nvidia_profiles.sh",
                configmaps=configmaps,
                skip_system_operations=True,
                extra_files=[(str(UTILS_SRC), UTILS_DEST)],
            )
        except Exception:
            # Script may fail, but container should be created
            pass
        
        # Ensure container exists
        if runner.container is None:
            raise RuntimeError("Container was not created by run_script")
        
        
        # Now run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        
        # Final profile name = {service}-{accelerator}-{intent}
        expected_workload_profile = f"nvidia-{accelerator}-{intent}"
        expected_final_profile = f"eks-{accelerator}-{intent}"
        assert_output_contains(result.stdout, "Requested service: eks")
        assert_output_contains(result.stdout, f"include={expected_workload_profile}")
        assert_output_contains(result.stdout, f"Final profile name: {expected_final_profile}")
        
        # Verify service profile directory exists (final name = eks-{accelerator}-{intent})
        profiles_dir = expected_profiles_dir(runner)
        service_profile_exists = runner.file_exists(f"{profiles_dir}/{expected_final_profile}/tuned.conf")
        assert service_profile_exists, f"EKS service profile {expected_final_profile} was not deployed"

        # Verify service profile includes the workload profile
        service_profile_content = runner.get_file_contents(
            f"{profiles_dir}/{expected_final_profile}/tuned.conf"
        )
        assert f"include={expected_workload_profile}" in service_profile_content, \
            f"EKS profile does not include {expected_workload_profile}"
        
        # Verify tuned_profile file points to final profile ({service}-{accelerator}-{intent})
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert tuned_profile_content.strip() == expected_final_profile, \
            f"tuned_profile should be '{expected_final_profile}', got: {tuned_profile_content!r}"
        
        # For EKS, verify bootloader script exists in final profile dir
        bootloader_script_exists = runner.file_exists(
            f"{profiles_dir}/{expected_final_profile}/bootloader.sh"
        )
        assert bootloader_script_exists, "EKS bootloader.sh script was not deployed"

        # Verify script.sh exists in final profile dir
        script_exists = runner.file_exists(f"{profiles_dir}/{expected_final_profile}/script.sh")
        assert script_exists, "EKS script.sh was not deployed"
        
    finally:
        runner.cleanup()


@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_with_aks_service(base_image, intent):
    """Test prepare_nvidia_profiles with AKS service for H100 across all intents."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": intent,
            "service": "aks",
        }

        # Create container directly
        create_container_for_testing(runner, configmaps)


        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)

        expected_workload_profile = f"nvidia-h100-{intent}"
        expected_final_profile = f"aks-h100-{intent}"
        assert_output_contains(result.stdout, "Requested service: aks")
        assert_output_contains(result.stdout, f"include={expected_workload_profile}")
        assert_output_contains(result.stdout, f"Final profile name: {expected_final_profile}")

        # Final profile directory exists with tuned.conf
        profiles_dir = expected_profiles_dir(runner)
        assert runner.file_exists(f"{profiles_dir}/{expected_final_profile}/tuned.conf"), \
            f"AKS service profile {expected_final_profile} was not deployed"

        # tuned.conf includes the workload profile
        service_profile_content = runner.get_file_contents(
            f"{profiles_dir}/{expected_final_profile}/tuned.conf"
        )
        assert f"include={expected_workload_profile}" in service_profile_content, \
            f"AKS profile does not include {expected_workload_profile}"

        # tuned_profile configmap points at the final profile name
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert tuned_profile_content.strip() == expected_final_profile, \
            f"tuned_profile should be '{expected_final_profile}', got: {tuned_profile_content!r}"

        # Per-service script plus shared helpers are all present and executable
        for helper in ("script.sh", "mac-address-policy.sh", "bootloader.sh"):
            path = f"{profiles_dir}/{expected_final_profile}/{helper}"
            assert runner.file_exists(path), f"{helper} was not deployed to {path}"

    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_eks_grub_config(base_image):
    """Test that EKS service creates the correct grub config file."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": "inference",
            "service": "eks",
        }
        
        # Create container directly
        create_container_for_testing(runner, configmaps)
        
        
        # Install grub-common for update-grub command (if available)
        if "ubuntu" in base_image or "debian" in base_image:
            runner.container.exec_run(
                ["apt-get", "install", "-y", "grub-common", "grub2-common"],
                workdir="/"
            )
        
        # Run prepare_nvidia_profiles in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        assert_exit_code(result, 0)
        
        # Create a mock /etc/tuned/bootcmdline file to simulate tuned writing it
        # Note: The bootcmdline file should contain the boot parameters as text
        runner.container.exec_run(
            ["bash", "-c", "mkdir -p /etc/tuned && echo 'TUNED_BOOT_CMDLINE=\"iommu=pt hugepages=8192\"' > /etc/tuned/bootcmdline"],
            workdir="/"
        )

        bootcmdline_content = runner.get_file_contents("/etc/tuned/bootcmdline")
        assert "TUNED_BOOT_CMDLINE=\"iommu=pt hugepages=8192\"" in bootcmdline_content, \
            "Bootcmdline file should contain the actual boot parameters (iommu=pt hugepages=8192)"
        
        # Final profile name = eks-h100-inference for this test's configmaps
        final_profile = "eks-h100-inference"
        profiles_dir = expected_profiles_dir(runner)
        # Run the EKS bootloader script (skip update-grub if it fails)
        bootloader_result = runner.container.exec_run(
            ["bash", "-c", f"{profiles_dir}/{final_profile}/bootloader.sh || true"],
            workdir="/"
        )
        
        # Verify grub config file was created
        grub_config_exists = runner.file_exists("/etc/default/grub.d/99_tuned.cfg")
        assert grub_config_exists, "Grub config file 99_tuned.cfg was not created"
        
        # Verify grub config file content
        grub_config_content = runner.container.exec_run(["bash", "-c", ". /etc/default/grub.d/99_tuned.cfg && echo $GRUB_CMDLINE_LINUX_DEFAULT"], workdir="/").output.decode('utf-8', errors='replace')
        assert_output_contains(grub_config_content, "iommu=pt")
        assert_output_contains(grub_config_content, "hugepages=8192")
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_default_intent(base_image):
    """Test that default intent is 'performance' when not specified."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            # No intent specified
        }
        
        # Create container directly
        create_container_for_testing(runner, configmaps)
        
        
        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "No intent specified, defaulting to: performance")
        assert_output_contains(result.stdout, "nvidia-h100-performance")
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_missing_accelerator(base_image):
    """Test that missing accelerator configmap causes error."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "intent": "performance",
            # No accelerator specified
        }
        
        # Create container directly
        create_container_for_testing(runner, configmaps)
        
        
        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 1)
        assert_output_contains(result.stdout, "accelerator configmap not found")
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_generic_accelerator(base_image):
    """Test that accelerator=generic uses nvidia-generic profile."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "generic",
        }
        
        # Create container directly
        create_container_for_testing(runner, configmaps)
        
        
        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Accelerator is generic, using profile: nvidia-generic")
        
        # Verify nvidia-generic profile was written to configmap
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert "nvidia-generic" in tuned_profile_content, \
            "Expected nvidia-generic in tuned_profile file"
        
        # Verify nvidia-generic profile directory exists in the version-resolved dir
        profiles_dir = expected_profiles_dir(runner)
        profile_exists = runner.file_exists(f"{profiles_dir}/nvidia-generic/tuned.conf")
        assert profile_exists, \
            f"nvidia-generic profile was not deployed to {profiles_dir}/"
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_generic_ignores_intent(base_image):
    """Test that accelerator=generic ignores intent and still uses nvidia-generic."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "generic",
            "intent": "inference",
        }
        
        create_container_for_testing(runner, configmaps)
        
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Accelerator is generic, using profile: nvidia-generic")
        
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert tuned_profile_content.strip() == "nvidia-generic", \
            f"Expected nvidia-generic, got: {tuned_profile_content!r}"
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_generic_ignores_service(base_image):
    """Test that accelerator=generic ignores service and still uses nvidia-generic."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "generic",
            "intent": "multiNodeTraining",
            "service": "eks",
        }
        
        create_container_for_testing(runner, configmaps)
        
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "Accelerator is generic, using profile: nvidia-generic")
        
        # Should NOT create a service-wrapped profile
        tuned_profile_content = runner.get_file_contents(
            "/skyhook-package/configmaps/tuned_profile"
        )
        assert tuned_profile_content.strip() == "nvidia-generic", \
            f"Expected nvidia-generic (no service wrapping), got: {tuned_profile_content!r}"
        
        # Service profile directory should NOT exist
        profiles_dir = expected_profiles_dir(runner)
        service_profile_exists = runner.file_exists(f"{profiles_dir}/eks-generic-multiNodeTraining/tuned.conf")
        assert not service_profile_exists, \
            "Service profile should not be created when accelerator=generic"
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_generic_profile_content(base_image):
    """Test that nvidia-generic profile contains expected self-contained settings."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "generic",
        }
        
        create_container_for_testing(runner, configmaps)
        
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        assert_exit_code(result, 0)

        profiles_dir = expected_profiles_dir(runner)
        profile_content = runner.get_file_contents(
            f"{profiles_dir}/nvidia-generic/tuned.conf"
        )

        # Self-contained: no include directive
        assert "include=" not in profile_content, \
            "nvidia-generic should be self-contained with no include"
        
        # No bootloader section (ineffective in virtualized environments)
        assert "[bootloader]" not in profile_content, \
            "nvidia-generic should not have a bootloader section"
        
        # CPU governor
        assert "governor=performance" in profile_content, \
            "nvidia-generic should set CPU governor to performance"
        
        # Sysctl
        assert "vm.swappiness=1" in profile_content, \
            "nvidia-generic should set vm.swappiness=1"
        assert "tcp_congestion_control=bbr" in profile_content, \
            "nvidia-generic should set BBR congestion control"
        assert "default_qdisc=fq" in profile_content, \
            "nvidia-generic should set fq qdisc"
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_generic_check_script(base_image):
    """Test that the check script verifies nvidia-generic correctly."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "generic",
        }
        
        create_container_for_testing(runner, configmaps)
        
        # Run prepare first
        prepare_result = run_script_in_container(
            runner, "prepare_nvidia_profiles.sh", configmaps
        )
        assert_exit_code(prepare_result, 0)
        
        # Run check
        check_result = run_script_in_container(
            runner, "prepare_nvidia_profiles_check.sh", configmaps
        )
        assert_exit_code(check_result, 0)
        assert_output_contains(
            check_result.stdout,
            "Accelerator is generic, verifying profile: nvidia-generic"
        )
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_eks_service_specific_profile(base_image):
    """Test that EKS service-specific inference profiles are used when available."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": "inference",
            "service": "eks",
        }
        
        # Create container directly
        create_container_for_testing(runner, configmaps)
        
        
        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        
        assert_exit_code(result, 0)
        
        # Verify that EKS-specific inference profile was deployed
        # (it should overwrite the OS profile)
        profiles_dir = expected_profiles_dir(runner)
        inference_profile_content = runner.get_file_contents(
            f"{profiles_dir}/nvidia-h100-inference/tuned.conf"
        )
        
        # EKS-specific profile should NOT have scheduler parameters set (they may be in comments)
        # Check that they're not set as actual sysctl parameters (not commented out)
        import re
        
        # Check for uncommented kernel.sched_latency_ns= lines
        latency_pattern = r'^\s*kernel\.sched_latency_ns\s*='
        assert not re.search(latency_pattern, inference_profile_content, re.MULTILINE), \
            "EKS-specific inference profile should not contain uncommented kernel.sched_latency_ns"
        
        # Check for uncommented kernel.sched_min_granularity_ns= lines
        granularity_pattern = r'^\s*kernel\.sched_min_granularity_ns\s*='
        assert not re.search(granularity_pattern, inference_profile_content, re.MULTILINE), \
            "EKS-specific inference profile should not contain uncommented kernel.sched_min_granularity_ns"
        
        # But should have vm.swappiness
        assert "vm.swappiness=1" in inference_profile_content, \
            "EKS-specific inference profile should contain vm.swappiness=1"
        
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_aks_service_specific_profile(base_image):
    """Test that AKS service-specific inference profile drops EEVDF-removed sysctls."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": "inference",
            "service": "aks",
        }

        create_container_for_testing(runner, configmaps)

        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)
        assert_exit_code(result, 0)

        # AKS-specific inference profile should have overwritten the OS profile
        # at {profiles_dir}/nvidia-h100-inference/tuned.conf
        profiles_dir = expected_profiles_dir(runner)
        inference_profile_content = runner.get_file_contents(
            f"{profiles_dir}/nvidia-h100-inference/tuned.conf"
        )

        import re
        # No uncommented kernel.sched_latency_ns= or kernel.sched_min_granularity_ns=
        latency_pattern = r'^\s*kernel\.sched_latency_ns\s*='
        assert not re.search(latency_pattern, inference_profile_content, re.MULTILINE), \
            "AKS-specific inference profile should not contain uncommented kernel.sched_latency_ns"
        granularity_pattern = r'^\s*kernel\.sched_min_granularity_ns\s*='
        assert not re.search(granularity_pattern, inference_profile_content, re.MULTILINE), \
            "AKS-specific inference profile should not contain uncommented kernel.sched_min_granularity_ns"

        # Core tunings retained
        assert "vm.swappiness=1" in inference_profile_content, \
            "AKS-specific inference profile should contain vm.swappiness=1"
        assert "AKS-compatible" in inference_profile_content, \
            "AKS-specific inference profile summary should identify it as AKS-compatible"

    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_common_service_rejected(base_image):
    """'common' is a reserved service name used for shared helpers; reject it explicitly."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": "performance",
            "service": "common",
        }

        create_container_for_testing(runner, configmaps)

        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        # Must fail with a clear message mentioning the reserved name
        assert result.exit_code != 0, \
            f"Expected prepare script to exit non-zero for service=common, got {result.exit_code}"
        assert "reserved service name" in result.stdout, \
            f"Expected stdout to mention 'reserved service name', got: {result.stdout!r}"

        # No common-* final profile dir should have been created
        profiles_dir = expected_profiles_dir(runner)
        assert not runner.file_exists(f"{profiles_dir}/common-h100-performance/tuned.conf"), \
            "common-h100-performance should NOT have been created"

    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_common_profiles_deployed(base_image):
    """Test that common base profiles are deployed to the version-resolved profiles dir."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {
            "accelerator": "h100",
            "intent": "performance",
        }

        # Create container directly
        create_container_for_testing(runner, configmaps)


        # Run the script in the same container
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)

        # Verify common profiles are deployed
        profiles_dir = expected_profiles_dir(runner)
        nvidia_base_exists = runner.file_exists(f"{profiles_dir}/nvidia-base/tuned.conf")
        assert nvidia_base_exists, f"nvidia-base profile was not deployed to {profiles_dir}/"

        nvidia_acs_disable_exists = runner.file_exists(f"{profiles_dir}/nvidia-acs-disable/tuned.conf")
        assert nvidia_acs_disable_exists, f"nvidia-acs-disable profile was not deployed to {profiles_dir}/"

    finally:
        runner.cleanup()


def _require_ubuntu_2604(base_image):
    """vr200 is supported on Ubuntu 26.04 only; skip elsewhere."""
    if "ubuntu" not in base_image or "26.04" not in base_image:
        pytest.skip(f"vr200 is Ubuntu 26.04 only; skipping for base image {base_image}")


@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_vr200_no_service(base_image, intent):
    """vr200 (no service) builds nvidia-vr200-<intent> on 26.04."""
    _require_ubuntu_2604(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "vr200", "intent": intent}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        expected_profile = f"nvidia-vr200-{intent}"
        profiles_dir = expected_profiles_dir(runner)
        assert runner.file_exists(f"{profiles_dir}/{expected_profile}/tuned.conf"), \
            f"vr200 profile {expected_profile} was not deployed to {profiles_dir}/"
    finally:
        runner.cleanup()


@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_vr200_base_keeps_bootloader(base_image, intent):
    """vr200 base (no service) profile chain retains [bootloader] tuning (gb200-faithful)."""
    _require_ubuntu_2604(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "vr200", "intent": intent}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        # The vr200-performance base (in the chain) carries [bootloader].
        profiles_dir = expected_profiles_dir(runner)
        perf = runner.get_file_contents(f"{profiles_dir}/nvidia-vr200-performance/tuned.conf")
        assert "[bootloader]" in perf, "vr200 performance base should keep [bootloader]"
    finally:
        runner.cleanup()


@pytest.mark.parametrize("intent", ["performance", "inference", "multiNodeTraining"])
def test_prepare_nvidia_profiles_vr200_bcm_no_bootloader(base_image, intent):
    """bcm-vr200 active chain contains NO [bootloader] stanza (applies without reboot)."""
    _require_ubuntu_2604(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "vr200", "intent": intent, "service": "bcm"}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        profiles_dir = expected_profiles_dir(runner)
        final_profile = f"bcm-vr200-{intent}"
        assert runner.file_exists(f"{profiles_dir}/{final_profile}/tuned.conf"), \
            f"bcm service profile {final_profile} was not deployed to {profiles_dir}/"
        # The bcm override re-roots the workload profile on the bootloader-free base.
        workload = runner.get_file_contents(f"{profiles_dir}/nvidia-vr200-{intent}/tuned.conf")
        assert "include=nvidia-vr200-noreboot-base" in workload, \
            "bcm vr200 workload profile must include the bootloader-free base"
        assert "[bootloader]" not in workload, "bcm vr200 workload profile must not have [bootloader]"
        noreboot = runner.get_file_contents(
            f"{profiles_dir}/nvidia-vr200-noreboot-base/tuned.conf"
        )
        assert "[bootloader]" not in noreboot, "noreboot base must not have [bootloader]"
    finally:
        runner.cleanup()


# --- rke2 service -------------------------------------------------------------------
#
# rke2 is the mirror image of bcm for the same accelerators: bcm re-roots onto a
# bootloader-free base so nothing needs a reboot, rke2 ships no overrides at all so each
# accelerator keeps its own [bootloader] stanza and the node reboots to pick it up.

# (accelerator, intent) pairs rke2 supports. gb300 ships a performance profile only.
RKE2_PAIRS = [
    ("gb200", "performance"),
    ("gb200", "inference"),
    ("gb200", "multiNodeTraining"),
    ("gb300", "performance"),
    ("vr200", "performance"),
    ("vr200", "inference"),
    ("vr200", "multiNodeTraining"),
]

# Accelerators whose performance profile carries a [script] stanza that a service-level
# [script] would suppress. See test_prepare_nvidia_profiles_rke2_ships_no_script.
ACCELERATORS_WITH_CONTAINERD_SCRIPT = ("gb200", "vr200")


class _ScriptResult:
    """Mirrors the TestResult shape run_script_in_container returns."""

    def __init__(self, exit_code, stdout):
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = ""


def _skip_unsupported_accelerator(base_image, accelerator):
    """vr200 profiles only exist under os/ubuntu/26.04; everything else is in os/common."""
    if accelerator == "vr200":
        _require_ubuntu_2604(base_image)


def _run_with_env(runner: DockerTestRunner, script: str, env: dict) -> _ScriptResult:
    """Run a lifecycle script with extra env layered onto the standard package env."""
    if runner.container is None:
        raise RuntimeError("Container must exist before running script")
    container_env = {
        "SKYHOOK_DIR": "/skyhook-package",
        "STEP_ROOT": "/skyhook-package/skyhook_dir",
        "SKIP_SYSTEM_OPERATIONS": "true",
        **env,
    }
    exec_result = runner.container.exec_run(
        ["/bin/bash", "-c", f"bash /skyhook-package/skyhook_dir/{script} 2>&1"],
        workdir="/skyhook-package",
        environment=container_env,
    )
    return _ScriptResult(exec_result.exit_code, exec_result.output.decode("utf-8", errors="replace"))


def _install_grub_stub(runner: DockerTestRunner):
    """Stub update-grub so the step's regeneration succeeds without a bootloader."""
    runner.container.exec_run(
        [
            "bash",
            "-c",
            "printf '#!/bin/sh\\ntouch /tmp/update-grub.ran\\n' > /usr/local/bin/update-grub "
            "&& chmod +x /usr/local/bin/update-grub",
        ],
        workdir="/",
    )


def _write_bootcmdline(runner: DockerTestRunner, path: str, cmdline: str):
    """Stand in for tuned resolving a profile's [bootloader] stanza."""
    runner.container.exec_run(
        ["bash", "-c", f"mkdir -p $(dirname {path}) && printf 'TUNED_BOOT_CMDLINE=\"%s\"\\n' '{cmdline}' > {path}"],
        workdir="/",
    )


# Paths the bootloader scripts take from the environment so tests do not touch real grub.
STUB_DROPIN = "/tmp/grub.d/99-nvidia-tuned-cmdline.cfg"
STUB_BOOTCMDLINE = "/tmp/tuned-bootcmdline"
STUB_PROC_CMDLINE = "/tmp/proc-cmdline"
STUB_ENV = {"TUNED_GRUB_DROPIN": STUB_DROPIN, "TUNED_BOOTCMDLINE": STUB_BOOTCMDLINE}

SAMPLE_CMDLINE = "iommu.passthrough=1 numa_balancing=disable hugepagesz=2M hugepages=8192"


@pytest.mark.parametrize("accelerator,intent", RKE2_PAIRS)
def test_prepare_nvidia_profiles_rke2_keeps_bootloader(base_image, accelerator, intent):
    """rke2 leaves the accelerator's [bootloader] chain intact, unlike bcm."""
    _skip_unsupported_accelerator(base_image, accelerator)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": accelerator, "intent": intent, "service": "rke2"}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        profiles_dir = expected_profiles_dir(runner)
        final_profile = f"rke2-{accelerator}-{intent}"
        workload_profile = f"nvidia-{accelerator}-{intent}"

        assert runner.file_exists(f"{profiles_dir}/{final_profile}/tuned.conf"), \
            f"rke2 service profile {final_profile} was not deployed to {profiles_dir}/"

        service_content = runner.get_file_contents(f"{profiles_dir}/{final_profile}/tuned.conf")
        assert f"include={workload_profile}" in service_content, \
            f"rke2 profile must include {workload_profile}, got: {service_content!r}"

        # The crux of the difference from bcm: no override re-roots the workload profile
        # onto a bootloader-free base, so it is the stock OS profile.
        workload_content = runner.get_file_contents(f"{profiles_dir}/{workload_profile}/tuned.conf")
        assert "noreboot-base" not in workload_content, \
            f"rke2 must not re-root {workload_profile} onto a bootloader-free base"

        # The root of every rke2 chain is the accelerator's performance profile, which is
        # where the kernel command line lives.
        perf_content = runner.get_file_contents(
            f"{profiles_dir}/nvidia-{accelerator}-performance/tuned.conf"
        )
        assert re.search(r"^\[bootloader\]", perf_content, re.MULTILINE) is not None, \
            f"nvidia-{accelerator}-performance should carry a [bootloader] section for rke2 to apply"
    finally:
        runner.cleanup()


@pytest.mark.parametrize("accelerator", ACCELERATORS_WITH_CONTAINERD_SCRIPT)
def test_prepare_nvidia_profiles_rke2_ships_no_script(base_image, accelerator):
    """rke2's template declares no [script], so the base profile's script survives.

    Only one [script] survives tuned's include chain. A service-level stanza (as eks,
    aks and oci declare) would silently suppress containerd_service.sh on exactly the
    accelerators rke2 targets, dropping the containerd LimitSTACK drop-in.
    """
    _skip_unsupported_accelerator(base_image, accelerator)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": accelerator, "intent": "performance", "service": "rke2"}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        profiles_dir = expected_profiles_dir(runner)

        service_content = runner.get_file_contents(
            f"{profiles_dir}/rke2-{accelerator}-performance/tuned.conf"
        )
        assert re.search(r"^\[script\]", service_content, re.MULTILINE) is None, \
            "rke2 must not declare a [script] section; it would suppress the base profile's script"

        assert runner.file_exists(
            f"{profiles_dir}/nvidia-{accelerator}-performance/containerd_service.sh"
        ), f"containerd_service.sh missing from nvidia-{accelerator}-performance"
    finally:
        runner.cleanup()


def test_prepare_nvidia_profiles_rke2_marker_not_deployed(base_image):
    """The bootloader.enabled marker is read by the agent step, so tuned never sees it."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "gb200", "intent": "performance", "service": "rke2"}
        create_container_for_testing(runner, configmaps)
        result = run_script_in_container(runner, "prepare_nvidia_profiles.sh", configmaps)

        assert_exit_code(result, 0)
        profiles_dir = expected_profiles_dir(runner)
        assert not runner.file_exists(f"{profiles_dir}/rke2-gb200-performance/bootloader.enabled"), \
            "bootloader.enabled must not be copied into the tuned profile directory"
        # It must still be readable where the lifecycle step looks for it.
        assert runner.file_exists("/skyhook-package/profiles/service/rke2/bootloader.enabled"), \
            "bootloader.enabled must remain in the package for configure_bootloader.sh to gate on"
    finally:
        runner.cleanup()



# --- configure_bootloader.sh and friends --------------------------------------------
#
# The grub.d drop-in only works on Debian-family distributions: sourcing
# /etc/default/grub.d/*.cfg is a Debian/Ubuntu patch to grub-mkconfig, and RHEL-family
# grub2-mkconfig ignores that directory. The step fails loudly there rather than writing
# a file nothing reads, so the matrix's rockylinux:9 entry exercises the rejection path
# while the Debian-family entries exercise the working one.

# Cleared so the stub update-grub actually runs. run_script_in_container sets
# SKIP_SYSTEM_OPERATIONS=true for the whole suite, and the step honours it by not
# touching the bootloader at all, which is the behavior test_..._skips_system_operations
# covers separately.
RUN_ENV = {**STUB_ENV, "SKIP_SYSTEM_OPERATIONS": ""}

STUB_OS_RELEASE = "/tmp/os-release-stub"

# A RHEL-family os-release, for exercising the rejection path on Debian-family images.
RHEL_OS_RELEASE = 'ID="rocky"\\nID_LIKE="rhel centos fedora"\\nPRETTY_NAME="Rocky Linux 9.4"\\n'


def _is_debian_family(base_image: str) -> bool:
    return "ubuntu" in base_image or "debian" in base_image


def _skip_non_debian(base_image):
    """The drop-in mechanism is Debian-family only; the step fails elsewhere by design."""
    if not _is_debian_family(base_image):
        pytest.skip(f"grub.d drop-ins are Debian-family only; skipping for {base_image}")


def _write_os_release(runner: DockerTestRunner, path: str, contents: str):
    runner.container.exec_run(["bash", "-c", f"printf '{contents}' > {path}"], workdir="/")


def _install_failing_grub_stub(runner: DockerTestRunner):
    """Stub update-grub as failing, to exercise the rollback paths."""
    runner.container.exec_run(
        ["bash", "-c", "printf '#!/bin/sh\\nexit 3\\n' > /usr/local/bin/update-grub "
                       "&& chmod +x /usr/local/bin/update-grub"],
        workdir="/",
    )


def _rke2_container(runner: DockerTestRunner, intent="performance", accelerator="gb200"):
    configmaps = {"accelerator": accelerator, "intent": intent, "service": "rke2"}
    create_container_for_testing(runner, configmaps)
    return configmaps


def test_configure_bootloader_writes_dropin(base_image):
    """The drop-in is written, grub is regenerated, and it resolves to the profile cmdline."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert runner.file_exists(STUB_DROPIN), f"drop-in was not written to {STUB_DROPIN}"
        assert runner.file_exists("/tmp/update-grub.ran"), "grub was not regenerated"

        # Evaluate the drop-in the way grub will, rather than matching its text.
        resolved = runner.container.exec_run(
            ["bash", "-c", f'. {STUB_DROPIN}; printf "%s" "$GRUB_CMDLINE_LINUX_DEFAULT"'],
            workdir="/",
        ).output.decode("utf-8", errors="replace")
        for token in SAMPLE_CMDLINE.split():
            assert token in resolved, f"{token} missing from resolved cmdline: {resolved!r}"

        check = _run_with_env(runner, "configure_bootloader_check.sh", RUN_ENV)
        assert_exit_code(check, 0)
    finally:
        runner.cleanup()


def test_configure_bootloader_refreshes_on_cmdline_change(base_image):
    """A changed cmdline regenerates grub even though the drop-in is byte-identical.

    The drop-in only sources /etc/tuned/bootcmdline, so changing intent rewrites that
    file while leaving the drop-in unchanged. Short-circuiting on unchanged drop-in
    content would leave the node booting the previous intent's cmdline.
    """
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)
        before = runner.get_file_contents(STUB_DROPIN)

        # New cmdline, and clear the regeneration marker so the rerun is what we observe.
        runner.container.exec_run(["bash", "-c", "rm -f /tmp/update-grub.ran"], workdir="/")
        changed = "iommu.passthrough=1 numa_balancing=disable hugepagesz=1G hugepages=2"
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, changed)

        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert runner.file_exists("/tmp/update-grub.ran"), \
            "grub must be regenerated when the sourced cmdline changes"
        assert runner.get_file_contents(STUB_DROPIN) == before, \
            "the drop-in itself should not change; only the file it sources does"

        resolved = runner.container.exec_run(
            ["bash", "-c", f'. {STUB_DROPIN}; printf "%s" "$GRUB_CMDLINE_LINUX_DEFAULT"'],
            workdir="/",
        ).output.decode("utf-8", errors="replace")
        assert "hugepages=2" in resolved, f"resolved cmdline not refreshed: {resolved!r}"
        assert "hugepages=8192" not in resolved, f"stale cmdline still resolving: {resolved!r}"
    finally:
        runner.cleanup()


def test_configure_bootloader_restores_dropin_when_grub_fails(base_image):
    """A failed regeneration puts the previous drop-in back rather than stranding a new one."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)
        original = runner.get_file_contents(STUB_DROPIN)

        _install_failing_grub_stub(runner)
        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert result.exit_code != 0, "a failed grub regeneration must fail the step"
        assert runner.file_exists(STUB_DROPIN), "the previous drop-in was not restored"
        assert runner.get_file_contents(STUB_DROPIN) == original, \
            "the restored drop-in does not match what was there before"
    finally:
        runner.cleanup()


def test_configure_bootloader_removes_new_dropin_when_grub_fails(base_image):
    """With no previous drop-in, a failed regeneration leaves nothing behind.

    Keeping it would strand a file the generated grub.cfg never referenced, which the
    next run would then treat as current.
    """
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_failing_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert result.exit_code != 0, "a failed grub regeneration must fail the step"
        assert not runner.file_exists(STUB_DROPIN), \
            "a drop-in grub never accepted must not be left on the host"
    finally:
        runner.cleanup()


def test_configure_bootloader_skips_system_operations(base_image):
    """SKIP_SYSTEM_OPERATIONS keeps the step off the real bootloader.

    The suite sets this for every step, so without the guard a missing stub would let a
    test regenerate the host's GRUB configuration.
    """
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        # STUB_ENV keeps the suite-wide SKIP_SYSTEM_OPERATIONS=true in place.
        result = _run_with_env(runner, "configure_bootloader.sh", STUB_ENV)
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "SKIP_SYSTEM_OPERATIONS set")
        assert not runner.file_exists("/tmp/update-grub.ran"), \
            "update-grub ran despite SKIP_SYSTEM_OPERATIONS"
        # The drop-in is still written; only the bootloader regeneration is skipped.
        assert runner.file_exists(STUB_DROPIN)
    finally:
        runner.cleanup()


def test_configure_bootloader_rejects_unsupported_os(base_image):
    """RHEL-family nodes fail loudly instead of getting a drop-in grub never reads.

    On the matrix's rockylinux:9 entry this runs against the real /etc/os-release; on the
    Debian-family entries it runs against a stub, so the path is covered either way.
    """
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        env = dict(RUN_ENV)
        if _is_debian_family(base_image):
            _write_os_release(runner, STUB_OS_RELEASE, RHEL_OS_RELEASE)
            env["OS_RELEASE"] = STUB_OS_RELEASE

        result = _run_with_env(runner, "configure_bootloader.sh", env)
        assert result.exit_code != 0, "the step must fail on a distribution it cannot support"
        assert_output_contains(result.stdout, "does not support the bootloader mechanism")
        assert not runner.file_exists(STUB_DROPIN), \
            "no drop-in should be written on a platform that cannot read it"
        assert not runner.file_exists("/tmp/update-grub.ran"), \
            "grub must not be regenerated on an unsupported platform"
    finally:
        runner.cleanup()


def test_configure_bootloader_disabled_by_env(base_image):
    """CONFIGURE_BOOTLOADER=false is the escape hatch, and silences all three checks.

    This is what an operator sets on a node whose kernel arguments are owned elsewhere,
    including any RHEL-family node that would otherwise be failed by the OS gate.
    """
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        env = {**RUN_ENV, "CONFIGURE_BOOTLOADER": "false", "PROC_CMDLINE": STUB_PROC_CMDLINE}
        for script in (
            "configure_bootloader.sh",
            "configure_bootloader_check.sh",
            "post_interrupt_bootloader_check.sh",
        ):
            result = _run_with_env(runner, script, env)
            assert_exit_code(result, 0)
            assert_output_contains(result.stdout, "switched off via CONFIGURE_BOOTLOADER")

        assert not runner.file_exists(STUB_DROPIN), "no drop-in should be written when switched off"
        assert not runner.file_exists("/tmp/update-grub.ran"), "grub must not be regenerated"
    finally:
        runner.cleanup()


def test_configure_bootloader_preserves_platform_cmdline(base_image):
    """The drop-in appends, so the platform's own arguments survive.

    Replacing GRUB_CMDLINE_LINUX_DEFAULT (what the older eks/aks script does) drops the
    serial console arguments an operator needs to reach a node that fails to boot.
    """
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)

        resolved = runner.container.exec_run(
            [
                "bash",
                "-c",
                f'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 quiet"; '
                f'. {STUB_DROPIN}; printf "%s" "$GRUB_CMDLINE_LINUX_DEFAULT"',
            ],
            workdir="/",
        ).output.decode("utf-8", errors="replace")

        assert "console=ttyS0,115200n8" in resolved, f"platform cmdline was dropped: {resolved!r}"
        assert "hugepages=8192" in resolved, f"profile cmdline was not appended: {resolved!r}"
    finally:
        runner.cleanup()


def test_configure_bootloader_noop_for_other_service(base_image):
    """Services without the marker (bcm here) get no drop-in and no grub regeneration.

    The service gate is checked before the OS gate, so this holds on every base image:
    a service that never wanted a drop-in is not failed for the platform it runs on.
    """
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "gb200", "intent": "performance", "service": "bcm"}
        create_container_for_testing(runner, configmaps)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "not enabled for this service")
        assert not runner.file_exists(STUB_DROPIN), \
            "bcm must not get a bootloader drop-in; it applies without a reboot"

        check = _run_with_env(runner, "configure_bootloader_check.sh", RUN_ENV)
        assert_exit_code(check, 0)
    finally:
        runner.cleanup()


def test_configure_bootloader_stands_down_when_service_changes(base_image):
    """Switching off rke2 removes the drop-in rather than leaving it applying forever."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)
        assert runner.file_exists(STUB_DROPIN)

        runner.container.exec_run(
            ["bash", "-c", "echo bcm > /skyhook-package/configmaps/service"], workdir="/"
        )
        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert not runner.file_exists(STUB_DROPIN), \
            "drop-in must be removed once the service stops opting in"
    finally:
        runner.cleanup()


def test_configure_bootloader_check_fails_without_dropin(base_image):
    """The check fails when the step was requested but left nothing behind."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        result = _run_with_env(runner, "configure_bootloader_check.sh", RUN_ENV)
        assert result.exit_code != 0, "check should fail when no drop-in exists"
        assert_output_contains(result.stdout, "no drop-in exists")
    finally:
        runner.cleanup()


def test_configure_bootloader_check_fails_on_inert_dropin(base_image):
    """A drop-in that is present but contributes nothing fails before the reboot.

    This is the failure worth catching early: a commented-out or overwritten drop-in
    reads as installed but leaves the node booting untuned.
    """
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        runner.container.exec_run(
            [
                "bash",
                "-c",
                f"mkdir -p $(dirname {STUB_DROPIN}) && "
                f"printf '# everything here is commented out\\n' > {STUB_DROPIN}",
            ],
            workdir="/",
        )

        result = _run_with_env(runner, "configure_bootloader_check.sh", RUN_ENV)
        assert result.exit_code != 0, "check should fail on a drop-in that resolves to nothing"
        assert_output_contains(result.stdout, "does not resolve to the profile's cmdline")
    finally:
        runner.cleanup()


def test_post_interrupt_bootloader_check_passes_when_cmdline_live(base_image):
    """After the reboot, every profile argument is present on the booted cmdline."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        runner.container.exec_run(
            ["bash", "-c",
             f"printf 'BOOT_IMAGE=/vmlinuz ro %s\\n' '{SAMPLE_CMDLINE}' > {STUB_PROC_CMDLINE}"],
            workdir="/",
        )

        result = _run_with_env(
            runner, "post_interrupt_bootloader_check.sh",
            {**RUN_ENV, "PROC_CMDLINE": STUB_PROC_CMDLINE},
        )
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "live after reboot")
    finally:
        runner.cleanup()


def test_post_interrupt_bootloader_check_fails_when_cmdline_absent(base_image):
    """A reboot that did not pick the drop-in up fails the node rather than passing it."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        # Booted without the profile arguments, e.g. a later-sorting grub.d file won.
        runner.container.exec_run(
            ["bash", "-c", f"printf 'BOOT_IMAGE=/vmlinuz ro quiet\\n' > {STUB_PROC_CMDLINE}"],
            workdir="/",
        )

        result = _run_with_env(
            runner, "post_interrupt_bootloader_check.sh",
            {**RUN_ENV, "PROC_CMDLINE": STUB_PROC_CMDLINE},
        )
        assert result.exit_code != 0, "check should fail when the cmdline did not take effect"
        assert_output_contains(result.stdout, "did not take effect")
        assert_output_contains(result.stdout, "hugepages=8192")
    finally:
        runner.cleanup()


def test_uninstall_bootloader_removes_dropin(base_image):
    """Uninstall removes the drop-in so the cmdline does not outlive the package."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)

        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)
        assert runner.file_exists(STUB_DROPIN)

        result = _run_with_env(runner, "uninstall_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert not runner.file_exists(STUB_DROPIN), "uninstall left the drop-in behind"

        check = _run_with_env(runner, "uninstall_bootloader_check.sh", RUN_ENV)
        assert_exit_code(check, 0)
    finally:
        runner.cleanup()


def test_uninstall_bootloader_skips_system_operations(base_image):
    """Uninstall honours SKIP_SYSTEM_OPERATIONS too; it is a registered lifecycle step."""
    _skip_non_debian(base_image)
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        assert_exit_code(_run_with_env(runner, "configure_bootloader.sh", RUN_ENV), 0)
        runner.container.exec_run(["bash", "-c", "rm -f /tmp/update-grub.ran"], workdir="/")

        result = _run_with_env(runner, "uninstall_bootloader.sh", STUB_ENV)
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "SKIP_SYSTEM_OPERATIONS set")
        assert not runner.file_exists("/tmp/update-grub.ran"), \
            "update-grub ran despite SKIP_SYSTEM_OPERATIONS"
        assert not runner.file_exists(STUB_DROPIN), "the drop-in should still be removed"
    finally:
        runner.cleanup()


def test_uninstall_bootloader_is_idempotent(base_image):
    """Removing a drop-in that was never written is a no-op, not a failure."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        _rke2_container(runner)

        result = _run_with_env(runner, "uninstall_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to remove")
    finally:
        runner.cleanup()


def test_configure_bootloader_leaves_foreign_dropin_alone(base_image):
    """Standing down must not delete a drop-in this package did not write.

    The eks and aks services write their own grub.d file from inside the tuned profile,
    and configure-bootloader runs after the profile is applied. Removing anything without
    its own marker would silently undo them on every config pass.
    """
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "h100", "intent": "inference", "service": "eks"}
        create_container_for_testing(runner, configmaps)
        _install_grub_stub(runner)
        _write_bootcmdline(runner, STUB_BOOTCMDLINE, SAMPLE_CMDLINE)
        runner.container.exec_run(
            [
                "bash",
                "-c",
                f"mkdir -p $(dirname {STUB_DROPIN}) && "
                f"printf 'GRUB_CMDLINE_LINUX_DEFAULT=\" ${{TUNED_BOOT_CMDLINE}}\"\\n' > {STUB_DROPIN}",
            ],
            workdir="/",
        )

        result = _run_with_env(runner, "configure_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert runner.file_exists(STUB_DROPIN), "the step removed a drop-in another service owns"
        assert "GRUB_CMDLINE_LINUX_DEFAULT" in runner.get_file_contents(STUB_DROPIN), \
            "the foreign drop-in was modified"
    finally:
        runner.cleanup()


def test_uninstall_bootloader_leaves_foreign_dropin_alone(base_image):
    """Uninstall is scoped to the drop-in this package wrote, by marker."""
    runner = DockerTestRunner(package="nvidia-tuned", base_image=base_image)
    try:
        configmaps = {"accelerator": "h100", "intent": "inference", "service": "eks"}
        create_container_for_testing(runner, configmaps)
        _install_grub_stub(runner)
        runner.container.exec_run(
            [
                "bash",
                "-c",
                f"mkdir -p $(dirname {STUB_DROPIN}) && "
                f"printf 'GRUB_CMDLINE_LINUX_DEFAULT=\" ${{TUNED_BOOT_CMDLINE}}\"\\n' > {STUB_DROPIN}",
            ],
            workdir="/",
        )

        result = _run_with_env(runner, "uninstall_bootloader.sh", RUN_ENV)
        assert_exit_code(result, 0)
        assert_output_contains(result.stdout, "nothing to remove")
        assert runner.file_exists(STUB_DROPIN), "uninstall removed a drop-in another service owns"

        check = _run_with_env(runner, "uninstall_bootloader_check.sh", RUN_ENV)
        assert_exit_code(check, 0)
    finally:
        runner.cleanup()
