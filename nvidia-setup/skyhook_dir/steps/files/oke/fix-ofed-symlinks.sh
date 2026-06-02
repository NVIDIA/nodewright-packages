#!/usr/bin/env bash
# Convert absolute symlinks created by ofa_kernel-dkms to relative ones.
# The OFED dkms.conf creates absolute symlinks under /usr/src/ofa_kernel/<arch>/
# pointing to /usr/src/ofa_kernel-dkms/<arch>/<kernel>. We cannot change the
# upstream dkms.conf, so we fix them after the fact.
#
# Exit codes:
#   0 — at least one symlink was converted
#   2 — nothing to do (directory absent or no absolute symlinks to fix)
set -euo pipefail

readonly OFA_DIR="/usr/src/ofa_kernel"
readonly EXPECTED_TARGET_PREFIX="/usr/src/ofa_kernel-dkms/"
readonly LOG_PREFIX="fix-ofed-symlinks"

if [[ ! -d "$OFA_DIR" ]]; then
    echo "${LOG_PREFIX}: ${OFA_DIR} does not exist, nothing to do"
    exit 2
fi

fixed=0
skipped=0
while IFS= read -r -d '' link; do
    target=$(readlink "$link")

    # Only interested in absolute symlinks
    [[ "$target" == /* ]] || continue

    # Only rewrite symlinks that point into the ofa_kernel-dkms source tree;
    # other absolute symlinks (e.g. /etc/alternatives) are system-managed.
    if [[ "$target" != "${EXPECTED_TARGET_PREFIX}"* ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    rel_target=$(realpath --relative-to="${link%/*}" "$target")
    ln -snf "$rel_target" "$link"
    echo "${LOG_PREFIX}: ${link} -> ${rel_target} (was ${target})"
    fixed=$((fixed + 1))
done < <(find "$OFA_DIR" -type l -print0)

echo "${LOG_PREFIX}: ${fixed} symlink(s) converted, ${skipped} skipped"
[[ "$fixed" -gt 0 ]] && exit 0 || exit 2
