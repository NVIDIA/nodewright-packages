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

# Sourced by the host wrapper and the finite-stage adapter.

kata_absolute_path() {
    case "$1" in
        /*) ;;
        *) echo "$2 must be an absolute host path" >&2; return 1 ;;
    esac
    case "$1" in
        /|*/../*|*/./*|*/..|*/.|*$'\n'*|*$'\r'*)
            echo "$2 must name a host path without dot components or newlines" >&2
            return 1
            ;;
    esac
}

kata_resolve_distribution() {
    local profile="${SKYHOOK_ROOT_DIR:-${SKYHOOK_DIR:?}}/kata-runtime-profile"
    local -a saved=()
    if [[ -f "$profile" && ( -x /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 ||
        ${action:-} == uninstall || ${action:-} == check-removed ) ]]; then
        mapfile -t saved < "$profile"
        if [[ ${#saved[@]} != 4 ]]; then
            echo 'invalid saved Kata runtime profile' >&2
            return 1
        fi
    fi
    local distribution="${K8S_DISTRIBUTION:-auto}"
    if [[ ${#saved[@]} == 4 && ( "$distribution" == auto || "$distribution" == "${saved[0]:-}" ) ]]; then
        distribution="${saved[0]}"
        KATA_HOST_CONTAINERD_CONFIG_DIR="${CONTAINERD_CONFIG_DIR:-${saved[1]}}"
        KATA_CONTAINERD_SOCKET="${CONTAINERD_RUNTIME_SOCKET:-${saved[2]}}"
        export KATA_SAVED_RUNTIME_VERSION="${saved[3]}"
    elif [[ "$distribution" == auto ]]; then
        local unit candidate found=''
        for candidate in microk8s rke2 k3s k0s; do
            case "$candidate" in
                microk8s) unit=snap.microk8s.daemon-containerd ;;
                rke2) unit=rke2-agent ;;
                k3s) unit=k3s-agent ;;
                k0s) unit=k0sworker ;;
            esac
            if systemctl is-active --quiet "$unit" ||
                { [[ "$candidate" == rke2 ]] && systemctl is-active --quiet rke2-server; } ||
                { [[ "$candidate" == k3s ]] && systemctl is-active --quiet k3s; } ||
                { [[ "$candidate" == k0s ]] && systemctl is-active --quiet k0scontroller; }; then
                if [[ -n "$found" ]]; then
                    echo 'multiple Kubernetes distributions are active; set K8S_DISTRIBUTION' >&2
                    return 1
                fi
                found="$candidate"
            fi
        done
        distribution="${found:-k8s}"
    fi
    local config_dir socket
    case "$distribution" in
        k8s) config_dir=/etc/containerd; socket=/run/containerd/containerd.sock ;;
        k3s) config_dir=/var/lib/rancher/k3s/agent/etc/containerd; socket=/run/k3s/containerd/containerd.sock ;;
        rke2) config_dir=/var/lib/rancher/rke2/agent/etc/containerd; socket=/run/k3s/containerd/containerd.sock ;;
        microk8s) config_dir=/var/snap/microk8s/current/args; socket=/var/snap/microk8s/common/run/containerd.sock ;;
        k0s) config_dir=/etc/k0s; socket=/run/k0s/containerd.sock ;;
        *) echo 'K8S_DISTRIBUTION must be auto, k8s, k3s, rke2, microk8s or k0s' >&2; return 1 ;;
    esac
    export K8S_DISTRIBUTION="$distribution"
    export KATA_HOST_CONTAINERD_CONFIG_DIR="${KATA_HOST_CONTAINERD_CONFIG_DIR:-${CONTAINERD_CONFIG_DIR:-$config_dir}}"
    export KATA_CONTAINERD_SOCKET="${KATA_CONTAINERD_SOCKET:-${CONTAINERD_RUNTIME_SOCKET:-$socket}}"
    KATA_CONTAINERD_SOCKET="${KATA_CONTAINERD_SOCKET#unix://}"
    KATA_HOST_CONTAINERD_CONFIG_DIR="${KATA_HOST_CONTAINERD_CONFIG_DIR%/}"
    kata_absolute_path "$KATA_HOST_CONTAINERD_CONFIG_DIR" CONTAINERD_CONFIG_DIR
    kata_absolute_path "$KATA_CONTAINERD_SOCKET" CONTAINERD_RUNTIME_SOCKET
    export CONTAINERD_CONFIG_FILE_NAME="${CONTAINERD_CONFIG_FILE_NAME:-config.toml}"
    case "$CONTAINERD_CONFIG_FILE_NAME" in
        .|..|*/*|*$'\n'*|*$'\r'*|[[:space:]]*|*[[:space:]])
            echo 'CONTAINERD_CONFIG_FILE_NAME must be a simple filename under the selected config directory' >&2
            return 1 ;;
    esac
    if [[ "$distribution" != k8s && "$CONTAINERD_CONFIG_FILE_NAME" != config.toml ]]; then
        echo 'custom config filenames are supported only for standalone containerd; other distributions select their own template' >&2
        return 1
    fi
}

kata_detect_containerd_version() {
    local -a client=()
    # Prefer the distribution's own client; fall back to a host-installed ctr.
    case "$K8S_DISTRIBUTION" in
        rke2)
            local data_dir="${KATA_HOST_CONTAINERD_CONFIG_DIR%/agent/etc/containerd}"
            if [[ -x "$data_dir/bin/ctr" ]]; then client=("$data_dir/bin/ctr"); fi
            ;;
        k3s|k0s|microk8s)
            if command -v "$K8S_DISTRIBUTION" >/dev/null 2>&1; then
                client=("$K8S_DISTRIBUTION" ctr)
            elif [[ "$K8S_DISTRIBUTION" == microk8s && -x /snap/bin/microk8s.ctr ]]; then
                client=(/snap/bin/microk8s.ctr)
            fi
            ;;
    esac
    if [[ ${#client[@]} == 0 ]]; then client=(ctr); fi
    local version
    if ! version="$("${client[@]}" --address "$KATA_CONTAINERD_SOCKET" --timeout 10s version |
        awk '/^Server:/ { server = 1; next }
             server && $1 == "Version:" { version = $2 }
             END { sub(/^v/, "", version); if (version != "") print version }')"; then
        echo "could not query the running containerd server at $KATA_CONTAINERD_SOCKET" >&2
        return 1
    fi
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
        echo 'could not determine the running containerd server version' >&2
        return 1
    fi
    printf 'containerd://%s\n' "$version"
}

kata_save_distribution() {
    local profile="${SKYHOOK_ROOT_DIR:-${SKYHOOK_DIR:?}}/kata-runtime-profile"
    (
        umask 077
        printf '%s\n' "$K8S_DISTRIBUTION" "$KATA_HOST_CONTAINERD_CONFIG_DIR" \
            "$KATA_CONTAINERD_SOCKET" "$CONTAINER_RUNTIME_VERSION" > "$profile.tmp"
        mv "$profile.tmp" "$profile"
    )
}
