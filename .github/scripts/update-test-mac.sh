#!/usr/bin/env bash
# Update test (macOS): installs version N from its DMG, serves version N+1 from a local feed, lets N update itself
# (Squirrel.Mac, which exercises the self-signed update path), waits for N+1 to be installed and self-checks it.
# A version N built with MAC_SILENT_UPDATES false never installs an update itself: it only offers N+1 as a DMG to
# download by hand (exit code 15), so there is nothing to wait for or to self-check.
# The release that switches the flag off (NEXT_MAC_SILENT_UPDATES=false, N+1's flag) is tested against a version N
# built with silent updates on. When Squirrel.Mac rejects the update (exit code 12), such an N shows the banner that
# links to the DMG instead, which is what the release sets out to do, so the test passes on that too. Without
# NEXT_MAC_SILENT_UPDATES=false, exit code 12 fails the test.
#
# Usage: update-test-mac.sh <version N dmg> <version N> <feed dir> <version N+1> <output dir>
# The feed dir holds the N+1 zip for this architecture, its blockmap and the merged latest-mac.yml.
# The output dir receives the update-test and self-check reports and the feed server log.
# Environment: NEXT_MAC_SILENT_UPDATES, MAC_SILENT_UPDATES of version N+1 ('true' or 'false').
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <version N dmg> <version N> <feed dir> <version N+1> <output dir>" >&2
    exit 2
fi
from_dmg=$1
from_version=$2
feed=$3
to_version=$4
mkdir -p "$5"
out=$(cd "$5" && pwd)

FEED_PORT=8765
FEED_URL="http://127.0.0.1:$FEED_PORT/"
APP_TIMEOUT=300
INSTALL_TIMEOUT=180

work=$(mktemp -d)
server=
cleanup() {
    if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# shellcheck source=lib-mac.sh
source "$(cd "$(dirname "$0")" && pwd)/lib-mac.sh"

update_exit_meaning() { # <exit code of --update-test>
    case $1 in
    10) echo 'no update found in the feed' ;;
    11) echo 'checking for or downloading the update failed' ;;
    12) echo 'macOS rejected the signature of the update (Squirrel.Mac code signature check)' ;;
    13) echo 'native update error' ;;
    14) echo 'the app watchdog stopped the update test (240 s)' ;;
    124) echo "the app did not exit within $APP_TIMEOUT s" ;;
    *) echo 'unexpected exit code' ;;
    esac
}

echo "Installing version N ($from_version) from $from_dmg"
install_dmg "$from_dmg" "$from_version"
app=$installed_app

echo "Checking that N+1 satisfies the designated requirement of N"
zips=("$feed"/*.zip)
if [ "${#zips[@]}" -ne 1 ] || [ ! -f "${zips[0]}" ]; then fail "expected one zip in $feed"; fi
mkdir "$work/next"
ditto -x -k "${zips[0]}" "$work/next"
next_apps=("$work/next"/*.app)
[ -d "${next_apps[0]}" ] || fail "no .app in ${zips[0]}"
check_designated_requirement "$app" "${next_apps[0]}"

echo "Serving N+1 ($to_version) on $FEED_URL"
python3 -m http.server "$FEED_PORT" --bind 127.0.0.1 --directory "$feed" >"$out/feed-server.log" 2>&1 &
server=$!
curl -sf --retry 10 --retry-connrefused "${FEED_URL}latest-mac.yml" >/dev/null || fail 'the local feed did not start'

echo "Running N in update-test mode"
defaults write "$APP_ID" ApplePersistenceIgnoreState YES
exe=$(bundle_executable "$app")
code=0
run_with_timeout "$APP_TIMEOUT" env "CW_UPDATE_FEED_URL=$FEED_URL" "$exe" \
    --update-test "--update-test-report=$out/update-test.json" || code=$?
if [ "$code" -eq 15 ]; then
    check_manual_offer "$out/update-test.json" "$to_version"
    echo "Update test passed: $from_version offers $to_version for a download by hand"
    exit 0
fi
if [ "$code" -eq 12 ] && [ "${NEXT_MAC_SILENT_UPDATES:-}" = false ]; then
    check_signature_rejected "$out/update-test.json" "$to_version"
    echo "Update test passed: macOS rejected the signature of $to_version, which has silent updates off;" \
        "$from_version shows the banner that links to the $to_version DMG instead"
    exit 0
fi
[ "$code" -eq 0 ] || fail "the update test exited with $code: $(update_exit_meaning "$code")"

echo "Waiting for the update to be installed"
waited=0
until [ "$(bundle_version "$app" 2>/dev/null || true)" = "$to_version" ]; do
    if [ "$waited" -ge "$INSTALL_TIMEOUT" ]; then
        fail "after $INSTALL_TIMEOUT s the installed version is $(bundle_version "$app" 2>/dev/null || echo 'unreadable'), expected $to_version"
    fi
    sleep 5
    waited=$((waited + 5))
done

echo "Running the self-check of N+1"
report="$out/self-check-updated.json"
exe=$(bundle_executable "$app")
code=0
run_with_timeout "$APP_TIMEOUT" "$exe" --self-check "--self-check-report=$report" || code=$?
[ -f "$report" ] || fail "the self-check wrote no report (exit code $code)"
check_report "$report" "$to_version"
[ "$code" -eq 0 ] || fail "the self-check exited with $code"
echo "Update test passed: $from_version -> $to_version"
