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

## Verifying your change before you open a pull request

**Use the Makefile.** CI does, so running the same targets on your machine runs the gate itself rather than an approximation of it. The PR build runs `make validate-standalone` or `make validate-inherited` for every changed package, `make test-deps` followed by that package's pytest suite, and `make test-harness` when `tests/helpers/` changed. The License Headers workflow runs `make license-check`.

Run these from the repository root, scoped to what you changed:

```bash
# A package changed. <name> is the package directory, for example nvidia-tuned.
make validate-standalone PACKAGE=<name>   # standalone package, no FROM on a *-packages image
make validate-inherited PACKAGE=<name>    # inherited package: builds the image, then validates it
make test-package PACKAGE=<name>          # that package's integration tests

# The shared test harness under tests/helpers/ changed.
make test-harness

# Any source file changed (*.py, *.sh, *.yaml, *.yml, Dockerfile).
make license-check                        # exactly what the License Headers workflow runs
make license-fmt                          # adds or refreshes the headers if that check fails

# A shell script changed.
shellcheck path/to/script.sh

# A workflow under .github/workflows/ changed.
actionlint
```

`make test` runs every package's suite in parallel. CI never does that, because it only tests the packages a pull request touches, so reach for `make test-package` first and keep `make test` for changes to the shared harness or tooling.

Two prerequisites are yours to supply, and the Makefile installs neither:

- **A running container runtime.** Everything except `make license-check` needs one: the validation targets run the agent image, and the tests build and run throwaway containers. The validation targets use `podman` when it is on `PATH` and `docker` otherwise, but the test harness talks to Docker specifically (it drives `docker-py` and shells out to `docker build`), so Podman needs a Docker-compatible socket and a `docker` command.
- **A local Go toolchain**, for `make license-fmt` and `make license-check`. Both run [`google/addlicense`](https://github.com/google/addlicense) through `go run`.

The Python test dependencies are not yours to supply. `make test-deps` runs as a prerequisite of every test target and installs them into a `venv/` at the repository root, so a missing pytest is never a reason to skip a suite. `make help` lists every target.

[DEVELOPER.md](DEVELOPER.md) has the longer form of all of this, including the macOS `TMPDIR` trap that makes every test fail with an error that does not point at the cause.

On a fork, running the checks locally is the fast path rather than the slow one. Workflow runs from a fork wait for a maintainer to approve them by hand, so a round trip through CI costs hours where the same checks locally cost minutes.

Not every check blocks. ShellCheck is advisory today: it annotates findings without failing the build, and the workflow's stated goal is to make it a required check once the existing findings reach zero. Treat a new finding in a file you touched as yours to fix rather than as something CI let through. Commitlint does block, on both the commit messages and the pull request title; see [Code Style](#code-style).

### Testing a package change on real hardware

Green checks do not mean a package change has been tested. ShellCheck, the integration tests and the license check look at the shape of a change: whether the script parses, whether the lifecycle scripts run to completion in a container, whether `config.json` matches the schema. They say very little about its effect on a host. Packages touch bootloaders, tuned profiles, drivers, disks and similar node state, and none of that is reachable from a container in CI.

So a change to a package has to be exercised on a real node, and the pull request has to say on what. This is not a formality. A maintainer reviewing your change often does not have the hardware to reproduce it, which means an untested package change is not something review can catch. You are the person best placed to verify it, and usually the only one.

Say, in the pull request:

- the OS and version you ran on,
- the relevant hardware, including the GPU model and driver version where the change depends on them,
- how you applied the package: through the operator, or by running the lifecycle scripts on the node directly,
- what you observed before and after, naming the command or file you checked.

If you cannot test on hardware, say that explicitly rather than leaving it unsaid. That is a useful answer: it tells review what risk it is accepting and lets a maintainer decide whether to find a node to try it on. Silence is not a useful answer, because a pull request that says nothing looks exactly like one that was tested.

## Stay with your pull request

Opening the pull request is the start of the work, not the end of it. Every one costs a maintainer time they do not get back: someone reads the change, thinks about it, and writes a review. That cost is paid whether or not anyone answers the review. Answer review comments, rebase when you are asked to, and say something if you get stuck or lose interest in a change. A pull request that is opened and abandoned is worse than one that was never opened, because the review still happened.

If it goes quiet from our side, ping it; that is welcome and it is the fastest way to get it moving. If it goes quiet from yours, a bot nudges you after 7 days of inactivity, the pull request is marked stale at 14 days, and it is closed 7 days after that. Closing is not a judgment on the change and it is not final: reopen it whenever you are ready to pick it back up. The `lifecycle/frozen` and `do-not-merge` labels exempt a pull request from all of it when the work is deliberately parked.

The same consideration applies to how many you open at once. A few pull requests you are actively shepherding through review will land sooner than a queue that neither you nor the maintainers can keep up with, and a long queue makes the changes that matter harder to find. If you have a batch of changes in mind, get the first few merged before opening the rest.

## AI-Assisted Contributions Policy

We welcome the use of AI tools (e.g., Claude, GitHub Copilot, ChatGPT) to help you write code, brainstorm, or refactor. However, we maintain a strict human-in-the-loop policy for all submissions:

- **Full accountability**: By submitting a PR, you (the human author) accept full responsibility for the code: its correctness, security, maintainability, and license compliance. "The AI wrote it" is not an acceptable explanation for bugs or security flaws.
- **Understand what you submit**: Do not submit AI-generated code you do not fully understand. Reviewers expect you to explain and defend every line of code in your PR.
- **Follow the project rules**: Coding assistants must follow the guidance in [`AGENTS.md`](AGENTS.md), including running the linters and keeping docs in sync.
- **Say so, and say what you verified**: if an AI tool wrote a meaningful part of the change, note that in the pull request, and state which checks you ran, which you could not, and what hardware you tested on. All of that belongs in the pull request body rather than in a reply after someone asks. This is not about discouraging the tooling; it is about knowing how much of the verification burden has already been carried, because a change nobody has run is a change the reviewer has to run.

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
