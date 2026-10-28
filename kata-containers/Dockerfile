# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Pin the multi-platform index, not an individual architecture manifest.
# Keep the Kata payload independent of the operator-managed agent.
ARG KATA_DEPLOY_IMAGE=ghcr.io/kata-containers/kata-deploy:4.3.1@sha256:9f6bbd0972e6fa8c99f5a86b24503032cb87be602d22e830d1c917ba31b4db9f
FROM ${KATA_DEPLOY_IMAGE} AS kata

FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f AS package-config
RUN apk add --no-cache python3
ARG TARGETARCH
COPY --from=kata /usr/bin/kata-deploy /tmp/kata-deploy
COPY check-architecture.py /package/check-architecture.py
# Emulation can execute a foreign binary, so inspect its ELF header directly.
RUN python3 /package/check-architecture.py "${TARGETARCH}" /tmp/kata-deploy
COPY --from=kata /opt/kata-artifacts /package/artifacts
COPY prune-artifacts.py /package/prune-artifacts.py
RUN python3 /package/prune-artifacts.py "${TARGETARCH}" /package/artifacts
COPY --from=kata /opt/kata-artifacts/VERSION /tmp/KATA_VERSION
COPY configure.py config.json /package/
ARG KATA_VERSION
RUN if [ -n "$KATA_VERSION" ]; then \
        python3 /package/configure.py --version-file /tmp/KATA_VERSION \
            --expected-version "$KATA_VERSION" --output /package/config.json; \
    else \
        python3 /package/configure.py --version-file /tmp/KATA_VERSION \
            --output /package/config.json; \
    fi

FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f AS installer
ARG TARGETARCH
RUN case "${TARGETARCH}" in amd64|arm64) ;; *) exit 1 ;; esac
RUN apk add --no-cache bash util-linux curl jq
COPY --from=kata /usr/bin/kata-deploy /usr/bin/kata-deploy
COPY --from=package-config /package/artifacts /opt/kata-artifacts
COPY skyhook_dir/run-inner.sh /usr/local/bin/nodewright-kata-stage
COPY skyhook_dir/distribution.sh /usr/local/bin/distribution.sh
COPY skyhook_dir/smoke.sh /usr/local/bin/nodewright-kata-smoke
RUN mkdir -p /root /host /proc /sys /dev /custom-configs

# Fail the build for older kata-deploy images that lack the finite stage API.
RUN help="$(/usr/bin/kata-deploy --help)" && \
    for action in install-stage-selinux-policy install-stage-load-kernel-modules \
        install-stage-host-check install-stage-artifacts install-stage-cri \
        cleanup-stage-revert-cri cleanup-stage-remove-artifacts; do \
        echo "$help" | grep -q "$action" || exit 1; \
    done

FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
COPY --from=installer / /skyhook-package/skyhook_dir/installer-rootfs/
COPY --from=package-config /package/config.json /skyhook-package/config.json
COPY skyhook_dir /skyhook-package/skyhook_dir
