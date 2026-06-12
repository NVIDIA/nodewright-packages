<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# CLAUDE.md / AGENTS.md

This file provides guidance to coding agents (Claude Code, Cursor, Codex, etc.) when working in this repository.

The canonical file is `AGENTS.md` at the repo root. `CLAUDE.md` is a symlink to it, so agents that look for either name find the same content. Keep edits in `AGENTS.md`.

## Repository overview

This repo holds the pre-built **packages** consumed by the [NVIDIA NodeWright operator](https://github.com/NVIDIA/skyhook) (the operator repo is `NVIDIA/nodewright`, also known as `skyhook`). A package is a container image that the operator runs on a node to install, configure, tune, or clean up host-level software through a defined lifecycle.

This repo does **not** contain the operator, the agent, or any Go code. It is shell scripts (could be python, or any executable, but currently is all shell), `Dockerfile`s, package config, and Python-based tests/tooling.

**Rename status (Skyhook to NodeWright):** the project is being renamed from Skyhook to NodeWright. Many public names still use `skyhook` on purpose: the published image path (`ghcr.io/nvidia/skyhook-packages/...`), the CRD group (`skyhook.nvidia.com/v1alpha1`), the on-host `SKYHOOK_DIR`/`skyhook_dir` names, and the CLI. The GitHub repo itself is now `nodewright-packages` (with `skyhook-packages` redirecting). Do not "fix" `skyhook` to `nodewright` or vice versa; match whatever the surrounding code already uses.

## Repository layout

- **Each top-level directory that contains a `Dockerfile` is a package.** Current packages: `shellscript`, `tuning`, `tuned`, `kdump`, `nvidia-setup`, `nvidia-tuning-gke`, `nvidia-tuned`, `copy-fail`.
- `scripts/`: repo tooling (`validate.py`, `format_license.py`, `sync_labels.py`).
- `tests/integration/`: Docker-based pytest suites, one subdir per package that has tests (with hyphens converted to underscores, e.g. `nvidia-setup` to `nvidia_setup`; not every package has a subdir).
- `.github/`: workflows, the `build-package` composite action, issue/PR templates, `labels.yml`, `CODEOWNERS`.
- `docs/`: note that `docs/plans` and `docs/superpowers` are gitignored; `docs/` is not a tracked doc tree in this repo. Authoritative prose lives in the root `*.md` files below.

### Package internal structure

```
<package>/
├── Dockerfile          # copies package contents to /skyhook-package in the image
├── config.json         # package manifest, validated against the agent schema
├── README.md           # per-package usage docs
├── root_dir/           # files copied verbatim to the host root: root_dir/foo -> /foo
└── skyhook_dir/        # lifecycle scripts and static files the scripts use
```

## Adding a new package

A package becomes "real" to CI once its directory has a `Dockerfile`. Beyond the
package contents themselves, a few repo-wide places track the package set and must
be updated in the same change, or its label automation silently goes stale:

- `.github/labels.yml`: add a `package/<name>` label (same color family as the
  others). Run `make labels` to sync it to GitHub.
- `.github/labeler.yml`: add a `package/<name>` entry mapping `<name>/**` so PRs
  touching the package get labeled.
- `.github/ISSUE_TEMPLATE/bug_report_form.yml` and `feature_request_form.yml`: add
  `<name>` to the "Which package does this relate to?" dropdown so reporters can
  select it.
- `.github/workflows/triage.yaml`: add `<name>` to the `PACKAGES` list (keep the
  longest-name-first ordering so substring names like `tuned` don't shadow
  `nvidia-tuned`).

Keep these four in sync with each other; the dropdown value, the label suffix, the
labeler glob directory, and the triage `PACKAGES` entry are all the same package
directory name.

## How packages work (the contract you must not break)

- Everything under `/skyhook-package` in the image lands at `${SKYHOOK_DIR}` on the host. `skyhook_dir/` lands at `${STEP_ROOT}`. `root_dir/` is laid down at `/`.
- `config.json` must comply with the [skyhook agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1). It declares `schema_version`, `package_name`, `package_version` (semver), and a `modes` map that points each lifecycle stage at a script, arguments, accepted return codes, `on_host`, and `idempotence`.
- **Runtime metadata** available to scripts: `STEP_ROOT`, `SKYHOOK_DIR`, `${SKYHOOK_DIR}/configmaps` (the package's configmaps), and `${SKYHOOK_DIR}/node-metadata/` (`labels.json`, `annotations.json`, `packages.json`).
- **Lifecycle stages** (see `PACKAGE_LIFECYCLE.md` for the full contract): `apply`, `config`, `interrupt`, `post-interrupt`, `upgrade`, `uninstall`. Every action stage has a paired `-check` mode that validates the action succeeded. Stages must be **idempotent**.
  - Normal flow: `uninstall -> apply -> config -> interrupt -> post-interrupt`
  - Upgrade flow: `upgrade -> config -> interrupt -> post-interrupt`
- **Inherited packages** build `FROM` another package's published image (the `FROM` line contains `skyhook-packages` or `nodewright-packages`). Examples: `nvidia-tuned` inherits from `tuned`, `nvidia-tuning-gke` from `tuning`. An inherited package **may omit `config.json`** if it does not need its own; a standalone package **must** have one.

## Working in this repo: do this before committing

Run from the repo root unless noted. See `DEVELOPER.md` for the full pre-commit checklist.

- **License headers:** `make license-fmt` (wraps `scripts/format_license.py`). All source files carry the Apache 2.0 SPDX header.
- **Validate config:** `make validate-standalone PACKAGE=<name>` for standalone packages, or `make validate-inherited PACKAGE=<name>` for inherited ones (this builds the image first, then validates the assembled `/skyhook-package`). Validation runs in the `ghcr.io/nvidia/skyhook/agent:latest` container and needs Docker or Podman.
- **Test:** `make test` runs the whole Docker-based suite in parallel; `make test-package PACKAGE=<name>` runs one package's tests. Tests need a working Docker daemon and create a `venv/`.
- **Changelog (per package):** `make changelog-preview PACKAGE=<name>` to preview unreleased notes, `make changelog PACKAGE=<name>` to write `<package>/CHANGELOG.md`. Notes come from `git-cliff` (see `cliff.toml`), scoped by `--include-path <package>/**` and `--tag-pattern <package>/.*`.
- **Labels:** `make labels` syncs `.github/labels.yml` to GitHub (needs `gh` with write access).

### Commit and version conventions

- **Conventional Commits**, with the **package name as scope**: `feat(shellscript): ...`, `fix(tuning): ...`. This applies to **both commit messages and PR titles**: a squash-merge uses the PR title as the commit subject, and the planned enforcement (below) checks the title. Use `general` (or `general/ci`) as the scope for repo-wide or CI changes, and use exactly one type per message; combined types like `docs+ci` are not valid Conventional Commits.
- **CC is a documented convention, not yet CI-enforced.** Unlike the operator repo (which gates Conventional Commits with a commit-linting check on the PR title), nothing here verifies commit or PR-title format yet, so the discipline is on the author and reviewers. Adding that gate is tracked separately; until it lands, do not assume a malformed message or title will be caught for you.
- **Sign-off is required** (DCO). Use `git commit -s`.
- **Semantic versioning per package.** Bump `package_version` in the package's `config.json`, then tag as `<package>/<version>` (e.g. `tuned/1.3.0`). Each package versions independently.

## Writing style

For prose you author in this repo (docs, READMEs, PR descriptions, commit messages, review comments): **do not use em-dashes** (`—`). Use a colon, semicolon, comma, or full stop instead, and recast the sentence when no punctuation swap reads cleanly. Leave intact things that are not authored prose: en-dashes in numeric ranges (`24–27`), markdown horizontal rules (`---`), and any em-dash already inside quoted text or code.

Keep markdown well-formed: a single `#` H1 per file with headings nested in order (no skipped levels), fenced code blocks that carry a language hint (` ```bash `, ` ```yaml `), blank lines around headings, lists, and code fences, consistent list markers, tables with aligned pipes and a header separator row, and links/relative paths that actually resolve. When you edit a doc, preview the rendered markdown rather than trusting the raw text.

## Shell scripting conventions

Almost all package logic is bash. The existing scripts are not yet consistent (shebangs and `set` flags vary), so when you add or touch a script, move it toward this standard rather than matching the nearest neighbour:

- **Shebang:** `#!/usr/bin/env bash`.
- **Strict mode:** start scripts with `set -euo pipefail` so they fail fast on errors, unset variables, and broken pipes. Lifecycle `-check` scripts are the deliberate exception where a non-zero exit is the signal, not a crash; handle expected failures explicitly there.
- **Quote every expansion:** `"${var}"`, `"$@"`, `"$(cmd)"`. Unquoted expansions (shellcheck `SC2086`) are by far the most common issue in this repo and the main thing to avoid adding.
- **Prefer** `[[ ... ]]` over `[ ... ]`, `$(...)` over backticks, and declare-then-assign for command substitution (`local x; x="$(cmd)"`) so a failing command is not masked (`SC2155`).
- **Idempotence:** lifecycle scripts must be safe to re-run (see `PACKAGE_LIFECYCLE.md`); either rely on the agent's idempotence tracking or write the script so repeats are no-ops.
- **Lint locally** before pushing: `shellcheck path/to/script.sh`. CI runs shellcheck across all tracked `*.sh` files whenever a `.sh` file, `.shellcheckrc`, or the workflow changes (advisory today; it reports findings without blocking, and will become a required check as the count reaches zero). `SC1091` (can't follow runtime-sourced files like `${SKYHOOK_DIR}/...`) is suppressed via `.shellcheckrc`.

## CI and release mechanics

- **On PR (`pr_build.yaml`):** detects which package directories changed, then for each changed package runs validate, test, and a dev build tagged `<version>-dev.sha<short>`. Changed-package detection keys on a directory having a `Dockerfile`; `scripts/` and hidden dirs are skipped.
- **On tag push `<package>/<version>`:** two independent workflows run. `build_container.yaml` builds and pushes the multi-arch image (`linux/amd64,linux/arm64`) with a build-provenance attestation; `release.yml` creates the GitHub Release with `git-cliff` notes scoped to that package. The image build (here and in `pr_build.yaml`) goes through the `.github/actions/build-package` composite action. (`build_package.yml` is a reusable `workflow_call` workflow that exists but is not currently wired up.)
- **Published image path:** `ghcr.io/nvidia/skyhook-packages/<package>:<version>` (the `skyhook-packages` segment is retained pending the rename).
- An optional `<package>/preprocess.sh` is run before the image build and can emit `BUILD_ARGS`.

## Keeping software current

Prefer the latest stable versions of the software this repo depends on, and keep
them moving forward rather than letting them drift. This covers base images in
`Dockerfile`s, the tools the lifecycle scripts invoke, the Python deps under
`tests/`, and the `uses:` actions in workflows. Staying current is how we pick up
upstream security and bug fixes.

Balance "latest" against reproducibility and supply-chain safety:

- **Pin GitHub Actions to a commit SHA** with the human-readable version in a
  trailing comment (e.g. `actions/labeler@f27b...e213  # v6.1.0`). To update, bump
  the SHA and the comment together; do not float a `@v6` tag.
- When you touch a file that references a pinned action, a base image tag, or a
  tool version, check whether a newer stable release exists and update it if the
  bump is safe. Treat a stale pin you are already editing as worth refreshing.

## Gotchas

- A new package is "real" once it has a `Dockerfile`; that is what CI keys on.
- Do not add a `config.json` to an inherited package unless it genuinely needs its own; CI treats a missing `config.json` as valid only when the `Dockerfile` inherits from a `skyhook-packages`/`nodewright-packages` image.
- Test directory names use underscores while package directories use hyphens (`nvidia-setup` to `tests/integration/nvidia_setup`).
- `docs/plans` and `docs/superpowers` are gitignored working areas, not shipped docs.

## Key references

- `README.md`: repository and per-package overview
- `PACKAGE_LIFECYCLE.md`: the lifecycle-stage contract
- `DEVELOPER.md`: validation and pre-commit steps
- `CONTRIBUTING.md`: DCO sign-off and commit style
- [NodeWright operator (`NVIDIA/skyhook`)](https://github.com/NVIDIA/skyhook): the operator that runs these packages
- [Agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1): the `config.json` contract
