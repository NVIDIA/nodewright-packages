#!/usr/bin/env bash
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


set -euo pipefail

case "${1:-}" in
    validate|prepare|check-prepared|install|uninstall|check-installed|check-removed|smoke) action=$1 ;;
    *) echo "usage: $0 {validate|prepare|check-prepared|install|uninstall|check-installed|check-removed|smoke}" >&2; exit 2 ;;
esac

: "${NODE_NAME:?set NODE_NAME using spec.nodeName in the package env}"
: "${CONTAINER_RUNTIME_VERSION:?set the reported containerRuntimeVersion}"
if [[ ! "$CONTAINER_RUNTIME_VERSION" =~ ^containerd://[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "CONTAINER_RUNTIME_VERSION must report a containerd server version" >&2
    exit 1
fi

# The same resolver validates direct calls and host-wrapper invocations.
source "${BASH_SOURCE[0]%/*}/distribution.sh"
kata_resolve_distribution
if [[ -n ${INSTALLATION_PREFIX:-}${MULTI_INSTALL_SUFFIX:-} ]]; then
    echo "installation prefixes and multiple installs are unsupported" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) echo 'unsupported node architecture' >&2; exit 1 ;;
esac
runtime=qemu-nvidia-cpu-runtime-rs
export SHIMS_X86_64="$runtime" SHIMS_AARCH64="$runtime"
export DEFAULT_SHIM_X86_64="$runtime" DEFAULT_SHIM_AARCH64="$runtime"
export SNAPSHOTTER_HANDLER_MAPPING_X86_64="$runtime:erofs"
export SNAPSHOTTER_HANDLER_MAPPING_AARCH64="$runtime:erofs"
export EXPERIMENTAL_SETUP_SNAPSHOTTER=erofs
export EROFS_SNAPSHOTTER_MODE="${EROFS_SNAPSHOTTER_MODE:-memory}"
export EROFS_DMVERITY="${EROFS_DMVERITY:-dmverity}"
if [[ "$action" == validate ]]; then
    exit 0
fi

if [[ "$action" == smoke ]]; then
    mkdir -p /run/kata-smoke
    mount -t tmpfs -o nodev,nosuid,noexec,size=1m tmpfs /run/kata-smoke
    exec /usr/local/bin/nodewright-kata-smoke
fi

# run.sh already runs on the host. enter-installer.sh creates a second chroot
# containing the bundled installer and mounts the host at /root inside it.
# Kata expects /host and the normalized paths below in that installer chroot.
# The outer unshare --propagation private keeps these mounts off the host.
mkdir -p /host
mount --bind /root /host

bind_dir() {
    mkdir -p "/root/$1" "$2"
    mount --bind "/root/$1" "$2"
}

bind_dir "${KATA_HOST_CONTAINERD_CONFIG_DIR#/}" /etc/containerd
bind_dir etc/crio /etc/crio
bind_dir opt/kata /opt/kata
bind_dir etc/systemd/system /etc/systemd/system
bind_dir run/systemd /run/systemd
bind_dir run/lock /host-run-lock
bind_dir etc/udev/rules.d /host-udev-rules.d
bind_dir etc/modules-load.d /host-modules-load.d
bind_dir boot /boot
bind_dir dev /host-dev
bind_dir usr/bin /host-usr/bin
bind_dir usr/sbin /host-usr/sbin
bind_dir usr/local/bin /host-usr-local/bin
bind_dir usr/local/sbin /host-usr-local/sbin
bind_dir bin /host-bin
bind_dir sbin /host-sbin
touch /host-machine-id
mount --bind /root/etc/machine-id /host-machine-id

if [[ -n ${SKYHOOK_DIR:-} && -d "$SKYHOOK_DIR/configmaps" ]]; then
    mkdir -p /custom-configs
    mount --bind "$SKYHOOK_DIR/configmaps" /custom-configs
    if [[ -f "$SKYHOOK_DIR/configmaps/containerd-user-dropin.toml" ]]; then
        export CONTAINERD_USER_DROP_IN_SOURCE_FILE=/custom-configs/containerd-user-dropin.toml
    fi
fi

case "$action" in
    prepare)
        kata-deploy install-stage-selinux-policy
        kata-deploy install-stage-load-kernel-modules
        kata-deploy install-stage-host-check
        ;;
    check-prepared)
        kata-deploy install-stage-host-check
        ;;
    install)
        kata-deploy install-stage-selinux-policy
        kata-deploy install-stage-load-kernel-modules
        kata-deploy install-stage-host-check
        kata-deploy install-stage-artifacts
        kata-deploy install-stage-cri
        ;;
    uninstall)
        kata-deploy install-stage-selinux-policy
        kata-deploy cleanup-stage-revert-cri
        # The pinned installer removes the installation directory itself. Hide
        # its individual bind mount with the host parent so rmdir can succeed.
        # Artifact extraction and the SELinux policy are no longer needed here.
        mount --bind /root/opt /opt
        kata-deploy cleanup-stage-remove-artifacts
        ;;
    check-installed)
        test -x /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
        test -s "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-$runtime.toml"
        ;;
    check-removed)
        test ! -e /opt/kata/runtime-rs/bin/containerd-shim-kata-v2
        ;;
esac
