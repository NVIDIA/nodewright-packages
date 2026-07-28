<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->
## Security

NVIDIA is dedicated to the security and trust of our software products and services, including all source code repositories managed through our organization.

If you need to report a security issue, please use the appropriate contact points outlined below. **Please do not report security vulnerabilities through GitHub.** If a potential security issue is inadvertently reported via a public issue or pull request, NVIDIA maintainers may limit public discussion and redirect the reporter to the appropriate private disclosure channels.

## Reporting Potential Security Vulnerability in an NVIDIA Product

To report a potential security vulnerability in any NVIDIA product:
- Web: [Security Vulnerability Submission Form](https://www.nvidia.com/object/submit-security-vulnerability.html)
- E-Mail: psirt@nvidia.com
    - We encourage you to use the following PGP key for secure email communication: [NVIDIA public PGP Key for communication](https://www.nvidia.com/en-us/security/pgp-key)
    - Please include the following information:
   	 - Product/Driver name and version/branch that contains the vulnerability
     - Type of vulnerability (code execution, denial of service, buffer overflow, etc.)
   	 - Instructions to reproduce the vulnerability
   	 - Proof-of-concept or exploit code
   	 - Potential impact of the vulnerability, including how an attacker could exploit the vulnerability

While NVIDIA currently does not have a bug bounty program, we do offer acknowledgement when an externally reported security issue is addressed under our coordinated vulnerability disclosure policy. Please visit our [Product Security Incident Response Team (PSIRT)](https://www.nvidia.com/en-us/security/psirt-policies/) policies page for more information.

## Coordinated Disclosure

PSIRT owns triage, severity assessment, and the disclosure date for reports filed through the channels above. What that means in this repository, while a report is under embargo:

- Maintainers will not discuss the report in public issues, pull requests, or discussions.
- A fix will not be merged with a commit message, pull request description, or test name that reveals the vulnerability ahead of the coordinated date.
- No package version will be tagged or announced in a way that advertises the issue before PSIRT publishes.
- The patched package release and the advisory ship together on the coordinated date, and the `CHANGELOG.md` entry links to the advisory.
- Reporters who ask to remain anonymous are credited as "an anonymous reporter" rather than by name.

## NVIDIA Product Security

For all security-related concerns, please visit NVIDIA's Product Security portal at https://www.nvidia.com/en-us/security

## Supported Versions

Each package in this repository is versioned and released independently, following [Semantic Versioning](https://semver.org/), and tagged as `{package}/{version}` (for example `shellscript/1.1.1`). Security fixes are released against the latest minor of the affected package.

| Package | Image | Supported |
|---|---|---|
| `shellscript/` | `ghcr.io/nvidia/skyhook-packages/shellscript` | Latest minor |
| `tuning/` | `ghcr.io/nvidia/skyhook-packages/tuning` | Latest minor |
| `tuned/` | `ghcr.io/nvidia/skyhook-packages/tuned` | Latest minor |
| `kdump/` | `ghcr.io/nvidia/skyhook-packages/kdump` | Latest minor |
| `nvidia-setup/` | `ghcr.io/nvidia/skyhook-packages/nvidia-setup` | Latest minor |
| `nvidia-tuned/` | `ghcr.io/nvidia/skyhook-packages/nvidia-tuned` | Latest minor |
| `nvidia-tuning-gke/` | `ghcr.io/nvidia/skyhook-packages/nvidia-tuning-gke` | Latest minor |
| `copy-fail/` | `ghcr.io/nvidia/skyhook-packages/copy-fail` | Latest minor |
| `bind-mount/` | `ghcr.io/nvidia/skyhook-packages/bind-mount` | Latest minor |

Older minors are not patched. If you pin a package version in a NodeWright custom resource, upgrade the pin to pick up a security fix. Published versions are on the [releases page](https://github.com/NVIDIA/nodewright-packages/releases).

These packages run **on the host, as root, through the NodeWright agent**. A vulnerability in a package step is a host-level issue, not a container-scoped one. Treat reports here with that in mind.

The operator and agent that execute these packages are versioned separately and have their own policy; see [NVIDIA/nodewright](https://github.com/NVIDIA/nodewright/blob/main/SECURITY.md).

## Verifying Release Artifacts

Every published package image is signed with [Sigstore cosign](https://docs.sigstore.dev/) in keyless mode and carries [SLSA v1 build provenance](https://slsa.dev/). The build workflow verifies its own signature and attestation before finishing, pinning the signer to an exact tag with no wildcard.

Verify a package image before you run it:

Verify by digest, not by tag. A tag can be repointed between the moment you verify it and the moment you pull it; a digest cannot. This is also what the build workflow itself does.

```bash
REPO=ghcr.io/nvidia/skyhook-packages/<package>
ISSUER=https://token.actions.githubusercontent.com
IDENTITY="https://github.com/NVIDIA/nodewright-packages/.github/workflows/build_container.yaml@refs/tags/<package>/<version>"

# Resolve the tag to an immutable digest once, then use it everywhere below
DIGEST=$(crane digest "$REPO:<version>")
IMAGE="$REPO@$DIGEST"

# Keyless signature
cosign verify --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" "$IMAGE"

# SLSA v1 build provenance
cosign verify-attestation --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  --type https://slsa.dev/provenance/v1 "$IMAGE"
```

Reference that same `$IMAGE` digest in the package `image` field of your NodeWright custom resource, so the artifact you verified is the artifact that runs.

Without `crane`, use:

```bash
DIGEST=$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$REPO:<version>")
```

Take the top-level manifest digest, which is what the signature and attestation are bound to. Do not substitute one of the per-platform digests listed under `Manifests:` in the plain `docker buildx imagetools inspect` output; those are children of the index and will not verify.

The certificate identity is the exact workflow and tag that built the image, so substitute the package and version you are verifying. Images published before the Skyhook to NodeWright repository rename carry a `NVIDIA/skyhook-packages` identity.

A verification failure on a published image is itself a security report. Route it through the channels above.
