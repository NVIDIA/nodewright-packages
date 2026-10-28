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

: "${NODE_NAME:?NODE_NAME is required}"
: "${KATA_SMOKE_TOKEN:?the smoke service-account token is required}"
: "${KATA_SMOKE_CA:?the Kubernetes CA is required}"
: "${KATA_SMOKE_API_HOST:=${KUBERNETES_SERVICE_HOST:-}}"
: "${KATA_SMOKE_API_PORT:=${KUBERNETES_SERVICE_PORT:-443}}"
: "${KATA_SMOKE_NAMESPACE:=kata-containers-smoke}"
: "${KATA_SMOKE_RUNTIME_CLASS:=kata-containers-qemu-nvidia-cpu-runtime-rs}"
: "${KATA_SMOKE_IMAGE:=docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e}"
: "${KATA_SMOKE_TIMEOUT:=300}"
: "${KATA_SMOKE_CLEANUP_TIMEOUT:=60}"
: "${KATA_SMOKE_WORK_DIR:=/run/kata-smoke}"

for duration in "$KATA_SMOKE_TIMEOUT" "$KATA_SMOKE_CLEANUP_TIMEOUT"; do
    if [[ ! "$duration" =~ ^[1-9][0-9]{0,4}$ ]]; then
        echo 'smoke timeouts must be positive seconds, at most 99999' >&2
        exit 1
    fi
done
if [[ ! "$KATA_SMOKE_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ || ${#KATA_SMOKE_NAMESPACE} -gt 63 ||
      ! "$KATA_SMOKE_RUNTIME_CLASS" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ || ${#KATA_SMOKE_RUNTIME_CLASS} -gt 253 ]]; then
    echo 'invalid smoke namespace or RuntimeClass name' >&2
    exit 1
fi
if [[ -z "$KATA_SMOKE_API_HOST" || "$KATA_SMOKE_API_HOST" == *[$'\r\n /?@#']* ||
      ! "$KATA_SMOKE_API_PORT" =~ ^[0-9]{1,5}$ ||
      ! "$KATA_SMOKE_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo 'invalid smoke API endpoint or service-account token format' >&2
    exit 1
fi
host="$KATA_SMOKE_API_HOST"
if [[ "$host" == *:* && "$host" != \[*\] ]]; then host="[$host]"; fi
api="https://${host}:${KATA_SMOKE_API_PORT}/api/v1/namespaces/${KATA_SMOKE_NAMESPACE}/pods"
seed="${SKYHOOK_RESOURCE_ID:-${SKYHOOK_DIR:?}}:${NODE_NAME}"
owner="$(printf '%s' "$seed" | sha256sum)"
owner="${owner%% *}"
name="nodewright-kata-smoke-${owner:0:20}"
uid=''
may_exist=false
http=''
deadline=$((SECONDS + KATA_SMOKE_TIMEOUT))

# Production mounts this directory as private tmpfs. Credentials never become
# part of a retained failed-stage payload, even if the process is killed.
umask 077
work="$(mktemp -d "${KATA_SMOKE_WORK_DIR}/check.XXXXXX")"
printf '%s\n' "$KATA_SMOKE_CA" > "$work/ca.crt"
printf 'header = "Authorization: Bearer %s"\n' "$KATA_SMOKE_TOKEN" > "$work/auth"
unset KATA_SMOKE_TOKEN KATA_SMOKE_CA

request() {
    local method="$1" path="$2" data="${3:-}"
    local -a arguments=(--silent --show-error --connect-timeout 5 --max-time 10
        --cacert "$work/ca.crt" --config "$work/auth"
        --output "$work/response" --write-out '%{http_code}' --request "$method")
    if [[ -n "$data" ]]; then arguments+=(--header 'Content-Type: application/json' --data-binary "@$data"); fi
    if ! http="$(curl "${arguments[@]}" "$api$path")"; then http=000; fi
}

owned() {
    jq -e --arg owner "$owner" --arg node "$NODE_NAME" --arg runtime "$KATA_SMOKE_RUNTIME_CLASS" '
        .metadata.annotations["nodewright.nvidia.com/kata-smoke-owner"] == $owner and
        .spec.nodeName == $node and .spec.runtimeClassName == $runtime and
        (.metadata.uid | type == "string" and length > 0)' "$work/response" >/dev/null
}

remove_pod() {
    [[ -n "$uid" ]] || return 0
    local cleanup_deadline=$((SECONDS + KATA_SMOKE_CLEANUP_TIMEOUT))
    jq -n --arg uid "$uid" '{apiVersion:"v1",kind:"DeleteOptions",gracePeriodSeconds:0,preconditions:{uid:$uid}}' > "$work/delete.json"
    while (( SECONDS < cleanup_deadline )); do
        request DELETE "/$name" "$work/delete.json"
        case "$http" in
            200|202|404) ;;
            000|429|500|502|503|504) sleep 1; continue ;;
            *) echo "cannot delete smoke pod $name: HTTP $http" >&2; return 1 ;;
        esac
        request GET "/$name"
        if [[ "$http" == 404 ]]; then uid=''; may_exist=false; return 0; fi
        if [[ "$http" == 200 ]] && ! jq -e --arg uid "$uid" '.metadata.uid == $uid' "$work/response" >/dev/null; then
            echo 'smoke pod identity changed during cleanup' >&2
            return 1
        fi
        case "$http" in
            200|000|429|500|502|503|504) sleep 1 ;;
            *) echo "cannot confirm smoke pod deletion: HTTP $http" >&2; return 1 ;;
        esac
    done
    echo "timed out confirming deletion of smoke pod $name" >&2
    return 1
}

# Called by the EXIT trap.
# shellcheck disable=SC2329
finish() {
    local status=$?
    trap - EXIT INT TERM
    # A create response may have been lost just before timeout or termination.
    if [[ "$may_exist" == true && -z "$uid" ]]; then
        request GET "/$name"
        if [[ "$http" == 200 ]] && owned; then
            uid="$(jq -r '.metadata.uid' "$work/response")"
        elif [[ "$http" != 404 ]]; then
            echo 'could not establish smoke pod identity for cleanup' >&2
            status=1
        fi
    fi
    if ! remove_pod; then status=1; fi
    rm -rf -- "$work"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A retry may find a pod left by an interrupted attempt. Only our own pod may
# be replaced, and UID preconditions protect a replacement with the same name.
while (( SECONDS < deadline )); do
    request GET "/$name"
    case "$http" in
        404) break ;;
        200)
            if ! owned; then echo "refusing to adopt unrelated pod $name" >&2; exit 1; fi
            uid="$(jq -r '.metadata.uid' "$work/response")"
            remove_pod
            break
            ;;
        000|429|500|502|503|504) sleep 1 ;;
        *) echo "cannot inspect smoke pod: HTTP $http" >&2; exit 1 ;;
    esac
done

jq -n --arg name "$name" --arg owner "$owner" --arg node "$NODE_NAME" \
    --arg runtime "$KATA_SMOKE_RUNTIME_CLASS" --arg image "$KATA_SMOKE_IMAGE" \
    --argjson timeout "$KATA_SMOKE_TIMEOUT" '{
    apiVersion:"v1",kind:"Pod",
    metadata:{name:$name,labels:{"app.kubernetes.io/managed-by":"nodewright"},
        annotations:{"nodewright.nvidia.com/kata-smoke-owner":$owner}},
    spec:{nodeName:$node,runtimeClassName:$runtime,restartPolicy:"Never",
        activeDeadlineSeconds:$timeout,terminationGracePeriodSeconds:5,
        automountServiceAccountToken:false,enableServiceLinks:false,
        securityContext:{runAsNonRoot:true,runAsUser:65534,runAsGroup:65534,seccompProfile:{type:"RuntimeDefault"}},
        tolerations:[{key:"node.kubernetes.io/unschedulable",operator:"Exists",effect:"NoSchedule"},
            {key:"nodewright.nvidia.com",operator:"Equal",value:"runtime-required",effect:"NoSchedule"}],
        containers:[{name:"guest",image:$image,imagePullPolicy:"IfNotPresent",command:["/bin/uname","-r"],
            resources:{requests:{cpu:"100m",memory:"256Mi"},limits:{cpu:"1",memory:"2Gi"}},
            securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}
    ' > "$work/pod.json"

while (( SECONDS < deadline )); do
    may_exist=true
    request POST '' "$work/pod.json"
    case "$http" in
        201) ;;
        409|000|429|500|502|503|504)
            # A response can be lost after the API server created the pod.
            request GET "/$name"
            if [[ "$http" != 200 ]]; then sleep 1; continue; fi
            ;;
        *) echo "cannot create smoke pod: HTTP $http" >&2; exit 1 ;;
    esac
    if ! owned; then echo "refusing to adopt unrelated pod $name" >&2; exit 1; fi
    uid="$(jq -r '.metadata.uid' "$work/response")"
    break
done
if [[ -z "$uid" ]]; then echo 'timed out creating the Kata smoke pod' >&2; exit 1; fi

while (( SECONDS < deadline )); do
    request GET "/$name"
    case "$http" in
        200)
            if ! owned || ! jq -e --arg uid "$uid" '.metadata.uid == $uid' "$work/response" >/dev/null; then
                echo 'smoke pod identity changed while waiting' >&2; exit 1
            fi
            phase="$(jq -r '.status.phase // "Pending"' "$work/response")"
            case "$phase" in
                Succeeded)
                    jq -e '.status.containerStatuses[] | select(.name == "guest") | .state.terminated.exitCode == 0' "$work/response" >/dev/null
                    remove_pod
                    printf 'Kata smoke pod succeeded on %s and was deleted\n' "$NODE_NAME"
                    exit 0
                    ;;
                Failed) echo "Kata smoke pod failed on $NODE_NAME" >&2; exit 1 ;;
            esac
            ;;
        000|429|500|502|503|504) ;;
        *) echo "cannot observe smoke pod: HTTP $http" >&2; exit 1 ;;
    esac
    sleep 1
done
echo "timed out waiting for the Kata smoke pod on $NODE_NAME" >&2
exit 1
