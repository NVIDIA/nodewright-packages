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

**Rename status (Skyhook to NodeWright):** the project is being renamed from Skyhook to NodeWright. New package releases publish at `ghcr.io/nvidia/nodewright-packages/...`; older package versions may still exist only under the legacy `ghcr.io/nvidia/skyhook-packages/...` namespace. The CRD group (`skyhook.nvidia.com/v1alpha1`), the on-host `SKYHOOK_DIR`/`skyhook_dir` names, and the CLI still use `skyhook` on purpose. The GitHub repo itself is now `nodewright-packages` (with `skyhook-packages` redirecting). Do not rename remaining `skyhook` references without checking their specific compatibility contract.

## Repository layout

- **Each top-level directory that contains a `Dockerfile` is a package.** Current packages: `shellscript`, `tuning`, `tuned`, `kdump`, `nvidia-setup`, `nvidia-tuning-gke`, `nvidia-tuned`, `copy-fail`, `bind-mount`.
- `scripts/`: repo tooling (`validate.py`, `sync_labels.py`, and `check-package-artifact.sh`, which checks a pushed package artifact against the spec).
- `tests/integration/`: Docker-based pytest suites, one subdir per package that has tests (with hyphens converted to underscores, e.g. `nvidia-setup` to `nvidia_setup`; not every package has a subdir).
- `.github/`: workflows, the composite actions (`build-package`, `build-package-artifact`, `wait-for-provenance`, `setup-oras`), issue/PR templates, `labels.yml`, `CODEOWNERS`.
- `docs/`: two tracked references, `docs/release-process.md` and `docs/artifact-locations.md` (which versions of each package image live under which registry path). `docs/plans` and `docs/superpowers` are gitignored working areas. Other authoritative prose lives in the root `*.md` files below.

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

- **License headers:** source files (`*.py`, `*.sh`, `*.yaml`/`*.yml`, `Dockerfile`) carry the full Apache 2.0 block header from `.github/license-header.tmpl`; Markdown and other docs do not need one. Run `make license-fmt` to add/refresh headers and `make license-check` to verify (the `License Headers` workflow runs the check on every PR and also fails on a duplicated header). Both wrap [`google/addlicense`](https://github.com/google/addlicense) via `go run`, so they need a local Go toolchain; addlicense is idempotent and never duplicates a header (it replaced the old `format_license.py`, which did, see #74).
- **Validate config:** `make validate-standalone PACKAGE=<name>` for standalone packages, or `make validate-inherited PACKAGE=<name>` for inherited ones (this builds the image first, then validates the assembled `/skyhook-package`). Validation runs in the `ghcr.io/nvidia/skyhook/agent:latest` container and needs Docker or Podman.
- **Test:** `make test` runs the whole Docker-based suite in parallel; `make test-package PACKAGE=<name>` runs one package's tests. Tests need a working Docker daemon and create a `venv/`.
- **Changelog (per package):** `<package>/CHANGELOG.md` is generated from Conventional Commit history by `git-cliff` (see `cliff.toml`); **do not hand-edit it in a PR.** Use `make changelog-preview PACKAGE=<name>` to preview the unreleased notes your commits will produce. The file is (re)written by `make changelog PACKAGE=<name>` at release time (scoped by `--include-path <package>/**` and `--tag-pattern <package>/.*`), so a PR that touches `CHANGELOG.md` will conflict with that regeneration and should be reverted.
- **`<package>/RELEASE_NOTES.md` is not a changelog, and most PRs do not belong in it.** At release, `release.yml` prepends the section for that version to the GitHub Release body, on top of the generated changelog that already records every change. Add a hand-written section only when the reader has to **do** something or will be **surprised**: an action required at upgrade time, a deprecation with a deadline, a behavior they will notice and did not ask for, a new knob worth discovering. A bug fix that restores intended behavior needs no entry, however involved the fix was. Default to not adding one; the commit message and the linked issue carry the reasoning.
- **Labels:** `make labels` syncs `.github/labels.yml` to GitHub (needs `gh` with write access).

### Commit and version conventions

- **Conventional Commits**, with the **package name as scope**: `feat(shellscript): ...`, `fix(tuning): ...`. This applies to **both commit messages and PR titles**: a squash-merge uses the PR title as the commit subject. Use `general` (or `general/ci`) as the scope for repo-wide or CI changes, and use exactly one type per message; combined types like `docs+ci` are not valid Conventional Commits.
- **CC is enforced in CI.** `.github/workflows/commit-linting.yaml` runs commitlint (`@commitlint/config-conventional`, configured in `commitlint.config.js`) against the PR title and every commit in the PR, so an invalid type, a non-CC subject, or a combined type like `docs+ci` fails the check. The subject-case rule is relaxed so capitalized subjects pass, and scope is not restricted to an enum. Lint locally with `echo "type(scope): subject" | npx @commitlint/cli@21 --config commitlint.config.js` (npx fetches commitlint if it is not installed); CI is the source of truth.
- **Sign-off and signing are both required.** Use `git commit -s -S`: `-s` adds the DCO `Signed-off-by` trailer, `-S` the GPG/SSH signature. `.github/workflows/commit-requirements.yaml` comments on PRs with a commit missing either (advisory, not yet a required check); bot commits are exempt and merge commits need only the signature.
- **Semantic versioning per package.** Bump `package_version` in the package's `config.json`, then tag as `<package>/<version>` (e.g. `tuned/1.3.0`). Each package versions independently.
- **Force-pushing a PR branch.** Review fixes may be folded into the existing commit (`git commit --amend -s -S --no-edit`) and force-pushed. Always push with `git push --force-with-lease --force-if-includes`, never a bare `--force`, which overwrites whatever is on the remote without looking. A `stale info` rejection means the branch moved since your last fetch (a maintainer's "Update branch", a co-author's commit, a bot fixup): fetch, find out what moved, and integrate it. It is not a cue to escalate to `--force`.

## Before you open a pull request

Run the checks CI runs, on your machine, before you push. This applies to a coding agent exactly as it does to a person.

- **Run the targets that match what you changed.** A package: `make validate-standalone PACKAGE=<name>` (or `make validate-inherited PACKAGE=<name>`) plus `make test-package PACKAGE=<name>`. The shared harness under `tests/helpers/`: `make test-harness`. Any `*.py`, `*.sh`, `*.yaml`, `*.yml` or `Dockerfile`: `make license-check`. A changed shell script: `shellcheck` on it. A changed workflow: `actionlint`. CI invokes those same make targets, so this is the gate rather than an approximation of it. A docs-only change needs none of it.
- **Supply the two prerequisites the Makefile does not.** Everything except `make license-check` needs a running container runtime, and the test harness talks to Docker specifically (`docker-py` plus a `docker build` call), so Podman needs a Docker-compatible socket and a `docker` command. `make license-fmt` and `make license-check` need a local Go toolchain. The Python test dependencies are installed for you into `venv/`, so a missing pytest means a target was bypassed. A tool you do not have is a fact to report in the pull request, never a reason to claim a suite passed.
- **A package change is not verified until it has run on a real node.** CI runs lifecycle scripts inside a container; it cannot touch bootloaders, tuned profiles, drivers or disks, which is most of what these packages do. The pull request must say which OS and version, which hardware (GPU model and driver version where the change depends on them), how the package was applied, and what was observed on the host before and after. You have no hardware, so say exactly that rather than writing anything that implies the change was exercised.
- **On a fork this is the fast path, not the slow one.** Workflow runs from a fork wait for a maintainer to approve them by hand, so pushing to see what CI says costs hours where the same checks locally cost minutes.
- **Every pull request links an issue assigned to its author.** Put `closes #N` in the PR body, and make sure the issue is assigned to the person the work is for before writing any code for it: comment `/assign`, or run `gh issue edit N --add-assignee @me` when it is unassigned. If the issue is already assigned to someone else, do not start; tell the user. The only exceptions are trivial changes (typos, broken links, comment fixes), Dependabot updates, and security fixes, which go through `SECURITY.md` and must never reference the non-public report. This applies to maintainers too.
- **Work-in-progress limit: three open PRs and three assigned issues per contributor, maintainers included.** Draft PRs count; Dependabot PRs do not, and neither do issues typed Epic or Initiative (their sub-issues count instead). The `/assign` bot enforces the issue half and refuses a fourth claim. Before opening a PR or claiming an issue, check `gh pr list --author @me --state open` and `gh issue list --assignee @me --state open --search "-type:Epic -type:Initiative"`. At three, stop and tell the user instead of opening or claiming a fourth. Release an issue you are no longer working on with `/unassign`.
- **Stay with the pull request after you open it.** A review costs a maintainer time whether or not anyone answers it, so respond to comments and rebase when asked. Inactive pull requests are nudged at 7 days, marked stale at 14, and closed 7 days later.
- **Write what you ran, what you could not, and what it ran on into the pull request body**, along with AI assistance if a tool wrote a meaningful part of the change. The rest of the process is in `CONTRIBUTING.md`.

## Issue and PR labels

- **`.github/labels.yml` is the closed set of labels.** It is the only source of truth, synced to GitHub with `make labels`. Because that sync creates and updates but never deletes, GitHub may carry undeclared extras; treat any label not defined in the file as one that should not exist, never as precedent for adding more.
- **Never create a label.** No `gh label create`, no `gh issue create --label <something-new>`, no label creation through `gh api`. A label invented once lingers on the repo until someone deletes it by hand. If a label you want is genuinely missing, add it to `.github/labels.yml` in a PR and stop there.
- **Priority is not a label.** It is a native GitHub issue Field (Urgent / High / Medium / Low) in the issue sidebar. **Maintainers set it during triage; agents and issue reporters do not set it at all.** Never apply `priority/*`, `P0` / `P1` / `P2`, or any severity label, and never write the Priority field from automation. If you think something is urgent, say so in the issue body and let a maintainer decide.
- **When filing an issue, apply no labels yourself.** The issue forms add their own type label, `.github/workflows/triage.yaml` adds `needs-triage` and infers `package/*`, and `.github/labeler.yml` labels PRs by path. Let that automation run rather than pre-labeling.

## Secrets and credentials

Hard boundaries: violating one means a rotation, not a revert.

- **Never commit credentials, API keys, tokens, passwords, kubeconfigs, or private keys.** Nothing secret belongs in a tracked file: not in a package's `skyhook_dir/` scripts or `root_dir/` files, not in `config.json`, not in a `Dockerfile` or anything it copies into an image layer, not in fixtures under `tests/`, not in `.github/workflows/`, and not in a commit message. Examples use an obvious placeholder (`REPLACE_ME`, `<your-token>`), never a real value that happens to be expired.
- **Never read a real credential into your output.** `~/.kube/config`, `~/.docker/config.json`, `~/.ssh/`, `~/.aws/`, and any `.env` are off limits: refer to them by path, never print them into the transcript, a file, or a PR description.
- **Secret-bearing environment variables stay out of tracked files.** CI reads them via `${{ secrets.* }}`; local runs read them from your shell. Do not add a `.env` with real values, and never give a secret-bearing variable a hardcoded fallback default.
- **Packages receive secrets at runtime, never baked in.** A package that needs a credential reads it from an environment variable that the package's `env` in the Skyhook CR sources from a Kubernetes Secret (`secretKeyRef`); see [providing secrets](https://github.com/NVIDIA/nodewright/blob/main/docs/user-guide/providing-secrets.md) in the operator repo. Never put one in an image layer or `config.json`, never document putting one in the package's configmap (a ConfigMap is not a Secret, and its contents land as plain files under `${SKYHOOK_DIR}/configmaps`), and never echo it or trace it with `set -x` in a lifecycle script.
- **Found a committed secret? Stop and report it.** Do not quietly delete it in a follow-up commit: the value survives in git history and has to be rotated regardless. Report it through `SECURITY.md`; do not open a public issue.

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
- **Image tags:** the image is tagged with the version exactly as written in the git tag, so `tuned/1.4.0` publishes `tuned:1.4.0` and `tuned/1.4.0-rc.1` publishes `tuned:1.4.0-rc.1`. A stable release also moves `latest`; a release candidate does not. Any other version form fails the build, matching what `release.yml` accepts.
- **Published image path for new releases:** `ghcr.io/nvidia/nodewright-packages/<package>:<version>`. Verify legacy versions before changing an existing consumer because some older tags remain only under `ghcr.io/nvidia/skyhook-packages/`; [docs/artifact-locations.md](docs/artifact-locations.md) lists which versions are on which path.
- **NGC staging:** after the GHCR build, the `publish-ngc` job in `build_container.yaml` copies the image by digest to `nvcr.io/1070195845945670/nodewright-packages/<package>:<version>`, from where NVIDIA's internal release process promotes it to the public `nvcr.io/nvidia` catalog. It copies with `oras cp -r`, so the keyless signatures (index and every platform manifest) and the provenance attestation come along unchanged; the job fails if the NGC digest differs from GHCR, then runs the same `cosign verify` checks against the copy. It runs in the `ngc-publish` environment, which holds `NGC_API_KEY` (a service key scoped to the `nodewright-packages` NGC team) and admits only `<package>/<version>` tags. An NGC failure leaves the GHCR release intact and can be re-run on its own. A package artifact (below) is copied and verified the same way by its own job, `publish-artifact-ngc`, to `nvcr.io/1070195845945670/nodewright-packages/<package>-artifact:<version>`.
- **Package artifacts:** every package is also published as a NodeWright package artifact (spec v1, from NVIDIA/nodewright#875), with no per-package configuration. After the image, the tag build (in its own `publish-artifact` job, so an artifact failure never holds up the image or its NGC staging) and the PR build run `.github/actions/build-package-artifact`: it reads `/skyhook-package` out of the pushed image, packs it reproducibly, builds the metadata from that payload's own `config.json` (uninstall `supported` when it has an `uninstall` mode, else `unsupported`), pushes it to `ghcr.io/nvidia/nodewright-packages/<package>-artifact:<tag>`, and checks it with `scripts/check-package-artifact.sh`. A package whose tree differs between amd64 and arm64 (today `kata-containers`) gets a warning and no artifact, since one artifact serves every node. Release builds also attest SLSA provenance, sign it keylessly, and verify both; PR builds do neither, and fork PRs skip the artifact because their image is not pushed. Artifacts never get `latest`.
- An optional `<package>/preprocess.sh` is run before the image build and can emit `BUILD_ARGS`.

## Code review (CodeRabbit)

`.coderabbit.yaml` configures CodeRabbit's automated PR review. Keep it in step with the repo so reviews stay useful, and update it in the same change that introduces the drift:

- **Guidance docs:** add new repo-guidance files to `knowledge_base.code_guidelines.filePatterns` (currently `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, `DEVELOPER.md`, `PACKAGE_LIFECYCLE.md`) so reviews enforce our conventions.
- **Generated or vendored content:** add new such paths to `reviews.path_filters` (currently the git-cliff-generated `CHANGELOG.md` and `RELEASE_NOTES.md`) so CodeRabbit does not review non-authored files.
- **Tools:** keep `reviews.tools` aligned with the linters we actually use. `shellcheck` is on and shares rules with CI via `.shellcheckrc`; revisit `yamllint` (currently off) if malformed YAML starts slipping through.

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
- `CONTRIBUTING.md`: DCO sign-off, commit signing, and commit style
- [NodeWright operator (`NVIDIA/skyhook`)](https://github.com/NVIDIA/skyhook): the operator that runs these packages
- [Agent schemas v1](https://github.com/NVIDIA/skyhook/tree/main/agent/skyhook-agent/src/skyhook_agent/schemas/v1): the `config.json` contract
