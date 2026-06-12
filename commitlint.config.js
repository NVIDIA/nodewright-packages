// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// commitlint configuration for skyhook-packages (NodeWright Packages).
// Enforces Conventional Commits on commit messages and PR titles via
// .github/workflows/commit-linting.yaml. See https://commitlint.js.org.

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // This repo writes capitalized subjects (e.g. "feat(tuned): Add support
    // for X"). config-conventional's default subject-case rule forbids
    // sentence-case, which would reject that style, so disable the case check
    // and let authors capitalize. Everything else (valid type, scope syntax,
    // non-empty subject, header length) is still enforced.
    'subject-case': [0],
    // Scope is conventionally the package name (e.g. kdump, tuned) or
    // "general"/"general/ci" for repo-wide changes, but it is not restricted
    // to an enum here so new packages do not require a config change.
    'header-max-length': [2, 'always', 100],
  },
};
