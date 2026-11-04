#!/usr/bin/env bash
# Merges the latest-mac.yml files of the arm64 and x64 builds into the one update feed file the release carries.
#
# electron-builder writes a latest-mac.yml per architecture. Uploading both would let the last upload win and leave
# the other architecture without updates. electron-updater picks the zip for its own architecture from `files`, so
# the merged file lists the files of both. The x64 file is the base: the legacy top-level `path` and `sha512` then
# name the x64 zip, which runs on both architectures. Fails when the two versions differ.
#
# Usage: merge-latest-mac.sh <arm64 latest-mac.yml> <x64 latest-mac.yml> <merged latest-mac.yml>
# Needs yq (mikefarah, v4) and jq.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <arm64 latest-mac.yml> <x64 latest-mac.yml> <merged latest-mac.yml>" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

yq -o=json '.' "$1" >"$work/arm64.json"
yq -o=json '.' "$2" >"$work/x64.json"
jq -s '
    if .[0].version != .[1].version
    then error("version mismatch: arm64 is \(.[0].version), x64 is \(.[1].version)")
    else . end
    | .[1] + {
        files: ((.[0].files + .[1].files) | unique_by(.url)),
        releaseDate: ([.[0].releaseDate, .[1].releaseDate] | max)
    }' "$work/arm64.json" "$work/x64.json" >"$work/merged.json"
yq -P -p=json -o=yaml '.' "$work/merged.json" >"$3"
