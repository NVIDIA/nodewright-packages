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

# Checks a pushed package artifact against a subset of the NodeWright package
# artifact spec v1 (NVIDIA/nodewright#875):
#
#   check-package-artifact.sh <registry>/<repository>@sha256:<hex>
#
# NodeWright ships no validation tool yet, so this restates the rules a producer
# here can get wrong: the manifest form and media types, the metadata
# document's fields and size, the payload's entry types and paths, and that the
# metadata embeds the payload's own config.json. It does not check what the
# agent decides at layout time (path segment rules beyond these, mode bits,
# overlay order across several layers), and it accepts only payload layers,
# the only kind this repository produces. Needs oras, jq and GNU tar.

set -euo pipefail

readonly MANIFEST_TYPE=application/vnd.oci.image.manifest.v1+json
readonly ARTIFACT_TYPE=application/vnd.nvidia.nodewright.package.v1
readonly CONFIG_TYPE=application/vnd.nvidia.nodewright.package.config.v1+json
readonly PAYLOAD_TYPE=application/vnd.nvidia.nodewright.package.payload.v1.tar+gzip
readonly MAX_METADATA_BYTES=1048576

if [[ $# -ne 1 || "$1" != *@sha256:* ]]; then
  echo "usage: $0 <registry>/<repository>@sha256:<hex>" >&2
  exit 2
fi
reference="$1"
repository="${reference%@*}"

fail() {
  echo "ERROR: ${reference}: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

oras manifest fetch --output "${work}/manifest.json" "${reference}"
manifest="${work}/manifest.json"

[[ "$(jq -r '.mediaType // empty' "${manifest}")" == "${MANIFEST_TYPE}" ]] \
  || fail "manifest mediaType must be ${MANIFEST_TYPE}; an index or Docker manifest is not a package artifact"
artifact_type="$(jq -r '.artifactType // empty' "${manifest}")"
[[ -z "${artifact_type}" || "${artifact_type}" == "${ARTIFACT_TYPE}" ]] \
  || fail "artifactType is ${artifact_type}, expected ${ARTIFACT_TYPE} or none"
[[ "$(jq -r '.config.mediaType' "${manifest}")" == "${CONFIG_TYPE}" ]] \
  || fail "config mediaType must be ${CONFIG_TYPE}"
config_size="$(jq -r '.config.size' "${manifest}")"
(( config_size > 0 && config_size <= MAX_METADATA_BYTES )) \
  || fail "metadata document is ${config_size} bytes; it must be between 1 and ${MAX_METADATA_BYTES}"
jq -e --arg payload "${PAYLOAD_TYPE}" \
  '(.layers | length) > 0 and all(.layers[]; .mediaType == $payload and .size > 0)' "${manifest}" > /dev/null \
  || fail "every layer must be a non-empty ${PAYLOAD_TYPE}; this repository produces no other layer kind"

metadata="${work}/metadata.json"
oras blob fetch --output "${metadata}" "${repository}@$(jq -r '.config.digest' "${manifest}")"
jq -e '
  type == "object"
  and (keys - ["config", "interrupt", "uninstall"] | length == 0)
  and (.uninstall == "supported" or .uninstall == "unsupported")
  and (.config | type == "object")
' "${metadata}" > /dev/null \
  || fail "metadata must hold uninstall (supported or unsupported) and a config object, and nothing but those and interrupt"

# Payload layers overlay in manifest order, so the last config.json wins.
mkdir -p "${work}/root"
index=0
while read -r digest; do
  layer="${work}/layer-${index}.tar.gz"
  oras blob fetch --output "${layer}" "${repository}@${digest}"

  # Regular files, directories and symlinks only. GNU tar's verbose listing
  # starts each entry with its type: '-' file, 'd' directory, 'l' symlink, and
  # 'h' (hard link), 'c', 'b' or 'p' for the kinds the agent refuses.
  tar -tvzf "${layer}" > "${work}/listing" || fail "layer ${digest} is not a gzip tar"
  bad="$(cut -c1 "${work}/listing" | grep -v '^[-dl]$' | sort -u | tr '\n' ' ' || true)"
  [[ -z "${bad}" ]] \
    || fail "layer ${digest} has entries of type '${bad% }'; only files, directories and symlinks are allowed"
  while IFS= read -r name; do
    [[ "${name}" != /* ]] || fail "layer ${digest} has an absolute entry ${name}"
    IFS=/ read -r -a segments <<< "${name}"
    for segment in "${segments[@]}"; do
      [[ "${segment}" != ".." ]] || fail "layer ${digest} has an entry escaping the root: ${name}"
      (( ${#segment} <= 255 )) || fail "layer ${digest} has a path segment over 255 bytes: ${name}"
    done
  done < <(tar -tzf "${layer}")

  # Archives may name the root entries with or without a ./ prefix; tar
  # extracts whichever of the two exists and complains about the other.
  # The metadata embeds config.json, so it must be a regular file, not a
  # symlink the agent would resolve somewhere else.
  if grep -qE ' (\./)?config\.json( |$)' "${work}/listing" \
      && ! grep -E ' (\./)?config\.json$' "${work}/listing" | cut -c1 | grep -qx -- '-'; then
    fail "layer ${digest} has a config.json at its root that is not a regular file"
  fi
  tar -xzf "${layer}" -C "${work}/root" config.json ./config.json 2> /dev/null || true
  index=$((index + 1))
done < <(jq -r '.layers[].digest' "${manifest}")

[[ -f "${work}/root/config.json" ]] || fail "no payload layer carries config.json at its root"
jq -e --slurpfile payload "${work}/root/config.json" '.config == $payload[0]' "${metadata}" > /dev/null \
  || fail "the metadata's config is not the payload's config.json; the agent rejects this as config-mismatch"

echo "${reference} is a valid package artifact (uninstall $(jq -r .uninstall "${metadata}"), ${index} payload layer(s))"
