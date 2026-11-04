#!/usr/bin/env bash
# Tests merge-latest-mac.sh. Run: bash .github/scripts/merge-latest-mac.test.sh
#
# The sample latest-mac.yml files are written as JSON, which is also valid YAML. Where yq is not installed, a
# stand-in that passes JSON through jq takes its place, so the merge logic can be tested anywhere jq runs. The yq
# conversions themselves only run where yq is installed (the ubuntu-latest runners have it).
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/merge-latest-mac.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! command -v yq >/dev/null; then
    mkdir "$work/bin"
    printf '#!/usr/bin/env bash\nfor last; do :; done\nexec jq . "$last"\n' >"$work/bin/yq"
    chmod +x "$work/bin/yq"
    PATH="$work/bin:$PATH"
fi

# Writes a latest-mac.yml the way electron-builder does for one architecture.
# Usage: write_feed <file> <version> <arch> <releaseDate>
write_feed() {
    cat >"$1" <<EOF
{
  "version": "$2",
  "files": [
    { "url": "context-workspace-$2-mac-$3.zip", "sha512": "zip-$3", "size": 100 },
    { "url": "context-workspace-$2-mac-$3.dmg", "sha512": "dmg-$3", "size": 200 }
  ],
  "path": "context-workspace-$2-mac-$3.zip",
  "sha512": "zip-$3",
  "releaseDate": "$4"
}
EOF
}

failures=0
report() { # <test name> <failure message, empty when the test passed>
    if [ -z "$2" ]; then
        echo "ok - $1"
    else
        echo "not ok - $1: $2"
        failures=$((failures + 1))
    fi
}

merges_both_architectures() {
    write_feed "$work/arm64.yml" 1.2.3 arm64 '2026-11-03T10:05:00.000Z'
    write_feed "$work/x64.yml" 1.2.3 x64 '2026-11-03T10:00:00.000Z'
    rm -f "$work/merged.yml"
    if ! bash "$script" "$work/arm64.yml" "$work/x64.yml" "$work/merged.yml"; then
        echo 'the script failed'
        return
    fi
    local actual expected
    actual=$(yq -o=json '.' "$work/merged.yml" | jq -cS '.files |= sort_by(.url)')
    expected=$(jq -cS '.files |= sort_by(.url)' <<'EOF'
{
  "version": "1.2.3",
  "files": [
    { "url": "context-workspace-1.2.3-mac-arm64.zip", "sha512": "zip-arm64", "size": 100 },
    { "url": "context-workspace-1.2.3-mac-arm64.dmg", "sha512": "dmg-arm64", "size": 200 },
    { "url": "context-workspace-1.2.3-mac-x64.zip", "sha512": "zip-x64", "size": 100 },
    { "url": "context-workspace-1.2.3-mac-x64.dmg", "sha512": "dmg-x64", "size": 200 }
  ],
  "path": "context-workspace-1.2.3-mac-x64.zip",
  "sha512": "zip-x64",
  "releaseDate": "2026-11-03T10:05:00.000Z"
}
EOF
    )
    if [ "$actual" != "$expected" ]; then
        echo "merged feed differs; expected $expected, got $actual"
    fi
}

fails_on_a_version_mismatch() {
    write_feed "$work/arm64.yml" 1.2.3 arm64 '2026-11-03T10:00:00.000Z'
    write_feed "$work/x64.yml" 1.2.4 x64 '2026-11-03T10:00:00.000Z'
    rm -f "$work/merged.yml"
    if bash "$script" "$work/arm64.yml" "$work/x64.yml" "$work/merged.yml" 2>"$work/stderr"; then
        echo 'the script succeeded'
    elif ! grep -q 'version mismatch' "$work/stderr"; then
        echo "stderr does not mention the version mismatch: $(cat "$work/stderr")"
    elif [ -e "$work/merged.yml" ]; then
        echo 'the script wrote a merged feed'
    fi
}

report 'merges both architectures' "$(merges_both_architectures)"
report 'fails on a version mismatch' "$(fails_on_a_version_mismatch)"
exit $((failures > 0))
