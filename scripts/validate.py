#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
Validation Script for NodeWright Packages

This script validates a config.json file against the skyhook-agent schema
and verifies that all referenced step files exist.
It is designed to run in the distroless skyhook-agent container.
"""

import json
import sys
import os
from jsonschema import ValidationError

try:
    from skyhook_agent import config
except ImportError as e:
    print(f"ERROR: Failed to import skyhook_agent.config: {e}", file=sys.stderr)
    print("This script must be run in the skyhook-agent container.", file=sys.stderr)
    sys.exit(1)


def is_executable(file_path: str) -> bool:
    """
    Check if a file has the executable bit set.
    
    Args:
        file_path: Path to the file to check
        
    Returns:
        True if the file is executable, False otherwise
    """
    if not os.path.exists(file_path):
        return False
    return os.access(file_path, os.X_OK)


def validate_executable_bits(config_path: str, config_data: dict, step_root_dir: str) -> bool:
    """
    Validate that all scripts referenced in config.json and all .sh files in the package
    have the executable bit set.
    
    Args:
        config_path: Path to the config.json file
        config_data: Parsed config.json data
        step_root_dir: Root directory where scripts are located (skyhook_dir)
        
    Returns:
        True if all scripts are executable, False otherwise
    """
    errors = []
    config_dir = os.path.dirname(os.path.abspath(config_path))
    
    # Collect all script paths referenced in config.json
    referenced_scripts = set()
    if 'modes' in config_data:
        for mode_name, steps in config_data['modes'].items():
            if isinstance(steps, list):
                for step in steps:
                    if isinstance(step, dict) and 'path' in step:
                        script_path = step['path']
                        referenced_scripts.add(script_path)
    
    # Check executable bits for scripts referenced in config.json
    for script_path in referenced_scripts:
        # Script paths in config.json are relative to step_root_dir (skyhook_dir)
        full_script_path = os.path.join(step_root_dir, script_path)
        if os.path.exists(full_script_path):
            if not is_executable(full_script_path):
                errors.append(f"Script referenced in config.json is not executable: {script_path} (full path: {full_script_path})")
        # Note: We don't error if the file doesn't exist here, as that's checked by config.load()
    
    # Find all .sh files in the package directory and check if they're executable
    package_dir = config_dir
    for root, dirs, files in os.walk(package_dir):
        # Skip hidden directories and common build artifacts
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        
        for file in files:
            if file.endswith('.sh'):
                file_path = os.path.join(root, file)
                if not is_executable(file_path):
                    # Make path relative to package_dir for cleaner error messages
                    rel_path = os.path.relpath(file_path, package_dir)
                    errors.append(f"Shell script is not executable: {rel_path} (full path: {file_path})")
    
    if errors:
        print("ERROR: Executable bit validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return False
    
    return True


def validate_config_file(config_path: str) -> bool:
    """
    Validate a config.json file against the skyhook-agent schema and verify step files exist.
    
    Args:
        config_path: Path to the config.json file to validate
        
    Returns:
        True if validation succeeds, False otherwise
    """
    # Check if file exists
    if not os.path.exists(config_path):
        print(f"ERROR: Config file not found: {config_path}", file=sys.stderr)
        return False
    
    # Load JSON file
    try:
        with open(config_path, 'r') as f:
            config_data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in {config_path}: {e}", file=sys.stderr)
        return False
    except IOError as e:
        print(f"ERROR: Failed to read {config_path}: {e}", file=sys.stderr)
        return False
    
    # Determine step_root_dir based on config.json location
    # config.json is at <package-dir>/config.json
    # skyhook_dir is at <package-dir>/skyhook_dir
    # In the container at runtime, this becomes /skyhook-package/skyhook_dir
    config_dir = os.path.dirname(os.path.abspath(config_path))
    skyhook_dir = os.path.join(config_dir, 'skyhook_dir')
    
    # Use /skyhook-package/skyhook_dir as requested by the user
    # This is the path structure used in the container at runtime
    # For validation, we use the actual filesystem path where files exist
    # since step.Steps.validate() uses os.path.exists() to check files
    step_root_dir = os.path.abspath(skyhook_dir)
    
    # Validate using config.load() which validates schema and step files
    try:
        # config.load() validates the schema, migrates if needed, and validates step files exist
        config.load(config_data, step_root_dir=step_root_dir)
        
        print(f"✓ Schema validation: passed")
        print(f"✓ Step files validation: passed")
        
        # Validate executable bits for scripts
        if not validate_executable_bits(config_path, config_data, step_root_dir):
            return False
        
        print(f"✓ Executable bit validation: passed")
        print(f"✓ Validation successful: {config_path}")
        return True
        
    except ValidationError as e:
        print(f"ERROR: Schema validation failed for {config_path}:", file=sys.stderr)
        print(f"  {e.message}", file=sys.stderr)
        if e.absolute_path:
            print(f"  Path: {'.'.join(str(p) for p in e.absolute_path)}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"ERROR: Validation failed for {config_path}: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return False


def main():
    """Main entry point for the validation script."""
    if len(sys.argv) != 2:
        print("Usage: validate.py <config.json>", file=sys.stderr)
        sys.exit(1)
    
    config_path = sys.argv[1]
    
    # Validate the config file
    if validate_config_file(config_path):
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
