## Description
<!-- Provide a standalone description of changes in this PR. -->
<!-- Reference any issues closed by this PR with "closes #1234". -->

## How this was verified
<!-- Which checks did you run, and which could you not run? Scope this to what you changed. -->
<!-- A package changed: `make validate-standalone PACKAGE=<name>` (or `make validate-inherited`) and `make test-package PACKAGE=<name>`. Both need a running container runtime. -->
<!-- tests/helpers/ changed: `make test-harness`. -->
<!-- A shell script changed: `shellcheck` on it. A workflow changed: `actionlint`. -->
<!-- Any source file changed (*.py, *.sh, *.yaml, *.yml, Dockerfile): `make license-check`. -->
<!-- Docs, comments or other non-code changes only: say so, that is a complete answer. -->
<!-- Could not run something (no Docker, for example)? Say which and why. -->

## Tested on
<!-- Required for a package change. The checks above test the shape of the change, not its effect on a host, -->
<!-- and a reviewer usually cannot reproduce your hardware. Tell us where this actually ran. -->
<!-- Example: Ubuntu 22.04, 8x H100 with driver 570.86.10, applied through the operator. -->
<!-- Before: `cat /proc/cmdline` had no iommu=pt. After: iommu=pt present, node rebooted clean, GPUs enumerated. -->
<!-- "Not tested on hardware, I do not have a node with this GPU" is an acceptable and useful answer. Saying nothing is not. -->
<!-- Not a package change? Write "n/a". -->

## Checklist
- [ ] I am familiar with the [Contributing Guidelines](https://github.com/NVIDIA/nodewright-packages/blob/HEAD/CONTRIBUTING.md).
- [ ] I ran the checks that apply to this change locally and recorded the result above.
- [ ] If this changes a package, the "Tested on" section above says what it ran on, or says plainly that it has not run on hardware.
- [ ] New or existing tests cover these changes.
- [ ] The documentation is up to date with these changes.
- [ ] If an AI tool wrote a meaningful part of this change, I have said so above, and I can explain and defend every line of it.
