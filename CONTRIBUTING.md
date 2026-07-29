<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Contributing

Want to contribute to NodeWright-Packages?

## Code of Conduct

This project is governed by the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating you are expected to uphold it. Report unacceptable behavior to GitHub_Conduct@nvidia.com. See [Community standards](#community-standards) for how reports are handled.

## Governance

Maintainers, decision-making, and the process for becoming a maintainer are documented in [GOVERNANCE.md](GOVERNANCE.md) and [MAINTAINERS.md](MAINTAINERS.md). Path-level review ownership is in [`.github/CODEOWNERS`](.github/CODEOWNERS).

## Developer Certificate of Origin (DCO)

The sign-off is a simple line at the end of the explanation for the patch. Your
signature certifies that you wrote the patch or otherwise have the right to pass
it on as an open-source patch. The rules are pretty simple: if you can certify
the below (from [developercertificate.org](http://developercertificate.org/)):

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.
1 Letterman Drive
Suite D4700
San Francisco, CA, 94129

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

Then you just add a line to every git commit message:

    Signed-off-by: Joe Smith <joe.smith@email.com>

Use your real name (sorry, no pseudonyms or anonymous contributions.)

If you set your `user.name` and `user.email` git configs, you can sign your
commit automatically with `git commit -s`.

## Claiming an Issue

Want to work on an issue? Claim it so others know it is taken. Comment on the issue and a bot will handle the assignment:

- `/assign`: assign the issue to yourself (only if it is currently unassigned).
- `/assign @user`: assign one other person (only if the issue is unassigned).
- `/unassign`: release your claim on the issue.

We use a single-owner model: an issue is assigned to at most one person. `/assign` is refused while the issue already has an assignee, and `/unassign` only ever removes your own claim, so nobody can drop someone else's. GitHub only lets you assign the commenter/self, someone who has commented on the issue, a user with write access, or an org member with read access; if a requested user cannot be assigned, the bot replies to say so.

## AI-Assisted Contributions Policy

We welcome the use of AI tools (e.g., Claude, GitHub Copilot, ChatGPT) to help you write code, brainstorm, or refactor. However, we maintain a strict human-in-the-loop policy for all submissions:

- **Full accountability**: By submitting a PR, you (the human author) accept full responsibility for the code: its correctness, security, maintainability, and license compliance. "The AI wrote it" is not an acceptable explanation for bugs or security flaws.
- **Understand what you submit**: Do not submit AI-generated code you do not fully understand. Reviewers expect you to explain and defend every line of code in your PR.
- **Follow the project rules**: Coding assistants must follow the guidance in [`AGENTS.md`](AGENTS.md), including running the linters and keeping docs in sync.

## Code Style

We use [Conventional Commits](https://www.conventionalcommits.org/) for our commit messages.

## License Header

Source files (`*.py`, `*.sh`, `*.yaml`/`*.yml`, `Dockerfile`) carry the full Apache 2.0
header defined in `.github/license-header.tmpl`. Markdown and other docs do not need one.
Add or refresh headers with:

```bash
make license-fmt
```

This wraps [`google/addlicense`](https://github.com/google/addlicense) (run via `go run`,
so a local Go toolchain is required); it is idempotent and never duplicates a header.
Run `make license-check` to verify without modifying files; CI runs the same check on
every PR.

## Community standards

We enforce the [Code of Conduct](CODE_OF_CONDUCT.md) in every project space: issues, pull requests, discussions, and any venue where someone is representing NodeWright Packages.

### Reporting

Send reports to GitHub_Conduct@nvidia.com. Include what happened, where, when, and links if the incident is public. You do not need to be the target of the behavior to report it.

### Response timeline

- **Acknowledgement within 3 business days.** You get a confirmation that the report was received and who is handling it.
- **Resolution within 14 business days** for most reports. If an investigation needs longer, we tell you that before day 14 and give an updated estimate.
- **Immediate action** for ongoing harassment, threats, or doxxing, ahead of the full investigation.

Reporter identity is shared only with the people investigating. Outcomes follow the [Enforcement Guidelines](CODE_OF_CONDUCT.md#enforcement-guidelines) ladder: correction, warning, temporary ban, permanent ban.

### Out of scope

The following are handled elsewhere, not through a conduct report:

- **Security vulnerabilities**: see [SECURITY.md](SECURITY.md). Do not file a public issue.
- **Technical disagreements**, including rejected pull requests and design decisions you disagree with. Escalate through the process in [GOVERNANCE.md](GOVERNANCE.md#decision-making).
- **Conduct in venues unrelated to NodeWright**, unless it creates a credible safety risk for someone in this community.
- **NVIDIA employment or HR matters**, which go through NVIDIA's internal channels.
