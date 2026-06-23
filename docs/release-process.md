<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Release process

Each package in this repo is versioned independently. A release is a git tag of
the form `<package>/<version>` with no `v` prefix, for example
`nvidia-setup/0.3.0`. Pushing such a tag triggers `.github/workflows/release.yml`,
which builds the release notes and creates the GitHub Release.

## Two-file model

Each package owns two changelog files:

- **`CHANGELOG.md`** is 100% machine-generated from git history by
  `scripts/gen-changelog.sh` and carries a DO-NOT-EDIT banner. Never hand-edit it;
  your changes will be overwritten on the next regeneration.
- **`RELEASE_NOTES.md`** is hand-authored. Add a `## <version>` section (bare
  version, e.g. `## 0.3.0`) for any release that needs upgrade or behavior notes
  beyond the commit log. On release, CI prepends the matching section to the
  GitHub Release body. Releases with no matching section just get the generated
  changelog.

## Versioning and release candidates

- Versions are semver `MAJOR.MINOR.PATCH`.
- Release candidates use the dotted suffix `-rc.N`, for example
  `nvidia-setup/0.3.0-rc.1`. The dot makes version sort order RCs correctly, and
  CI marks `-rc.N` tags as GitHub pre-releases so they do not become "Latest".
- Any tag that is neither `X.Y.Z` nor `X.Y.Z-rc.N` is rejected by the workflow.

Release-notes scoping is asymmetric:

- A **stable** release covers everything since the previous *stable* release (rc
  tags are excluded as boundaries, so stable notes are not truncated to the
  last-rc delta).
- A **release candidate** shows only the delta since the prior tag (rc or
  stable), which is what you want while iterating.

## Cutting a release

1. Make sure the package's changes are merged to `main`.
2. Regenerate the changelog with the version you are about to cut and commit it:

   ```bash
   make changelog PACKAGE=<name> VERSION=<version>   # e.g. VERSION=0.3.0
   git add <name>/CHANGELOG.md
   git commit -s -m "chore(<name>): update CHANGELOG"
   ```

   `VERSION` labels the commits since the last tag as that release instead of
   `[Unreleased]`. Omit it (or run `make changelog` with no args for the
   interactive picker) to just refresh `[Unreleased]`. Either way the CHANGELOG is
   fully regenerated from `git tag` on the next run, so a missed label self-heals.

   Add or update a `## <version>` section in `<name>/RELEASE_NOTES.md` if the
   release needs upgrade notes, and commit that too.
3. Cut and push the tag:

   ```bash
   make release-tag
   ```

   The helper prompts for the package, the bump (major/minor/patch), and whether
   this is a release candidate. It creates the tag on the current `HEAD` behind an
   explicit confirmation, then asks separately before pushing. Pushing the tag
   triggers the CI release.

## Make targets

| Target                            | Purpose                                                                 |
| --------------------------------- | ----------------------------------------------------------------------- |
| `make changelog [PACKAGE=<name>] [VERSION=<version>]` | Regenerate a package's `CHANGELOG.md`. Interactive picker when `PACKAGE` is omitted; `VERSION` labels the cut release instead of `[Unreleased]`. |
| `make changelog-preview PACKAGE=<name>` | Print the unreleased changes for a package without writing a file.  |
| `make release-tag`                | Interactively cut (and optionally push) a release tag.                  |

## Why tag-range generation

A single `git cliff --include-path <pkg>/** --tag-pattern <pkg>/.*` call is broken
for this monorepo: git-cliff path-filters the commit set first and then looks for
release tags only among the survivors, so a release tag whose commit touches no
files under the package path (version bumps, CI fixes, ride-along releases) is
dropped and its commits roll into `[Unreleased]`. Tags that live only on release
branches are also invisible from `main`.

`scripts/gen-changelog.sh` instead takes the release boundaries from `git tag` and
renders each section over an explicit `prevTag..curTag` range, so every release is
recovered. See `docs/plans/2026-06-12-changelog-tooling-design.md` and
orhun/git-cliff#1122, #208 for the full background.
