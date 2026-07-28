<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# NodeWright Packages Project Governance

This document describes how the NodeWright Packages project is governed: the roles people hold, how decisions get made, and how maintainers join and leave. It is intentionally lightweight and will grow with the project. For the current roster and maintainer responsibilities, see [MAINTAINERS.md](MAINTAINERS.md).

## Project Scope

This repository holds the first-party packages that [NodeWright](https://github.com/NVIDIA/nodewright) applies to cluster nodes. Each package is a container image with lifecycle steps (uninstall, upgrade, apply, config, interrupt, post-interrupt) that the NodeWright agent executes against the host.

In scope: the packages in this repository, their configuration schemas, the shared build tooling, and the tests that exercise them.

Out of scope: the NodeWright operator, agent, CRDs, and CLI, which live in [NVIDIA/nodewright](https://github.com/NVIDIA/nodewright). Third-party packages built by other teams are owned by their authors and are not governed here.

## Roles

NodeWright Packages uses three roles. Code ownership maps directly to [`.github/CODEOWNERS`](.github/CODEOWNERS).

### Contributors

Anyone who opens an issue, pull request, or discussion. Contributors follow the [Code of Conduct](CODE_OF_CONDUCT.md) and sign off their commits under the DCO (see [CONTRIBUTING.md](CONTRIBUTING.md)). No special access is required to contribute.

### Code Owners

Trusted contributors who review and approve pull requests for the paths they own. Code ownership is declared per path in [`.github/CODEOWNERS`](.github/CODEOWNERS), which GitHub uses to request reviews automatically. Code owners keep their areas healthy and mentor contributors.

### Maintainers

Maintainers have merge rights, make and ratify project decisions, manage releases, and own this governance process, including adding and removing maintainers. Maintainers are also code owners. The current roster is in [MAINTAINERS.md](MAINTAINERS.md).

## Areas of Ownership

Path-level ownership is authoritative in [`.github/CODEOWNERS`](.github/CODEOWNERS). At a high level the project is organized into:

- **Packages**: one directory per package (`bind-mount/`, `copy-fail/`, `kdump/`, `nvidia-setup/`, `nvidia-tuned/`, `nvidia-tuning-gke/`, `shellscript/`, `tuned/`, `tuning/`), each with its own `config.json`, README, and version.
- **Shared tooling** (`scripts/`, `makefile`): build, packaging, and release automation common to every package.
- **Tests** (`tests/`): the suites that validate package behavior.
- **CI** (`.github/`): workflows, issue and pull request templates, and release plumbing.
- **Documentation** (`PACKAGE_LIFECYCLE.md`, `DEVELOPER.md`, root project docs).

Maintainers hold cross-cutting responsibility across all areas.

## Decision-Making

NodeWright Packages decides by **lazy consensus**: a proposal (pull request, issue, or discussion) is accepted if no maintainer raises a blocking objection within a reasonable review window, at least five business days for non-trivial changes. Most day-to-day changes are merged through normal code-owner review under [`.github/CODEOWNERS`](.github/CODEOWNERS) and the process in [CONTRIBUTING.md](CONTRIBUTING.md).

When consensus is not reached:

- **Majority vote.** Any maintainer may call a vote. A proposal passes on a simple majority of non-emeritus maintainers; quorum is a simple majority of that same group.
- **Blocking objection (veto).** A maintainer may block a change by stating a concrete technical rationale and an actionable path to resolution. A blocked change proceeds only if a two-thirds supermajority of non-emeritus maintainers votes to override.
- **Supermajority decisions.** Adding or removing a maintainer, and changes to this document, require a two-thirds supermajority of non-emeritus maintainers.

Changes that alter a package's config schema, its lifecycle step contract, or its interrupt behavior always require an explicit approval from at least one maintainer who did not author the change, regardless of the review window. These surfaces are consumed by clusters running the operator, and a silent break there reaches production nodes.

## Tie-Breaking

If a vote is tied, the **lead maintainer** has the casting vote. The lead maintainer is designated by the maintainer team and recorded in [MAINTAINERS.md](MAINTAINERS.md); the role exists to break deadlocks and carries no additional day-to-day authority. If the lead maintainer is the subject of, or is recused from, a decision, the remaining maintainers designate an acting lead for that decision.

## Adding and Removing Maintainers

### Adding

Maintainers are added on merit. An existing maintainer nominates a candidate based on sustained contributions, review quality, and domain expertise. The nominee is added when a two-thirds supermajority of non-emeritus maintainers approves.

### Removing and stepping down

A maintainer may step down at any time by opening a pull request that moves them to emeritus. A maintainer may also be removed by a two-thirds supermajority of non-emeritus maintainers, for sustained inactivity (see [Emeritus](#emeritus)) or for conduct that violates the [Code of Conduct](CODE_OF_CONDUCT.md). Removal for cause follows the Code of Conduct enforcement process.

## Emeritus

A maintainer is considered **inactive** after six months with no substantive contribution, review, or governance participation. Inactive maintainers are moved to the Emeritus list in [MAINTAINERS.md](MAINTAINERS.md) either voluntarily, or involuntarily by the same two-thirds supermajority of non-emeritus maintainers required for removal. Moving to emeritus removes merge rights and excludes the maintainer from quorum and vote counts. Emeritus maintainers are welcomed back through the normal onboarding process when they return to active participation.

## Deprecation and End-of-Life

Packages are versioned independently and follow semver, as described in the Versioning section of the [README](README.md#versioning). Removing a package, or making a breaking change to its config schema or lifecycle contract, requires a deprecation notice in `CHANGELOG.md` and a migration path in the package's README before the removal ships. A package that no longer has a maintainer is marked deprecated rather than left to rot silently.

## Changing This Document

Amendments follow the supermajority rule above: a pull request plus approval from a two-thirds supermajority of non-emeritus maintainers.
