#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Sync GitHub labels from .github/labels.yml using the gh CLI.
# Usage: python3 scripts/sync_labels.py
#    or: make labels

import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    # Fall back to a minimal YAML parser for simple label files
    yaml = None

REPO_ROOT = Path(__file__).resolve().parent.parent
LABELS_FILE = REPO_ROOT / ".github" / "labels.yml"


def load_labels():
    with open(LABELS_FILE) as f:
        content = f.read()

    if yaml:
        return yaml.safe_load(content)

    # Minimal parser: handles simple list of {name, color, description} mappings
    labels = []
    current = {}
    for line in content.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("- name:"):
            if current:
                labels.append(current)
            current = {"name": line.split(":", 1)[1].strip().strip('"')}
        elif line.strip().startswith("color:"):
            current["color"] = line.split(":", 1)[1].strip().strip('"')
        elif line.strip().startswith("description:"):
            current["description"] = line.split(":", 1)[1].strip().strip('"')
    if current:
        labels.append(current)
    return labels


def get_repo():
    result = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("ERROR: Could not determine repo. Are you logged in with gh?")
        sys.exit(1)
    return result.stdout.strip()


def sync_label(repo, label):
    name = label["name"]
    color = label.get("color", "ededed")
    description = label.get("description", "")

    # Try to create; if it exists, edit instead
    result = subprocess.run(
        ["gh", "label", "create", name,
         "--color", color,
         "--description", description,
         "--repo", repo,
         "--force"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        print(f"  ✓ {name}")
    else:
        print(f"  ✗ {name}: {result.stderr.strip()}")
        return False
    return True


def main():
    labels = load_labels()
    repo = get_repo()
    print(f"Syncing {len(labels)} labels to {repo}...")

    ok = sum(sync_label(repo, l) for l in labels)
    failed = len(labels) - ok
    print(f"\nDone: {ok} synced, {failed} failed.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
