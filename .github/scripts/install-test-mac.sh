#!/usr/bin/env bash
# Install test (macOS): installs the app from the DMG the way a user does (copy to /Applications), checks its
# signature, starts it in self-check mode and checks the report.
#
# Usage: install-test-mac.sh <dmg> <expected version> <self-check report path>
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <dmg> <expected version> <self-check report path>" >&2
    exit 2
fi
dmg=$1
version=$2
mkdir -p "$(dirname "$3")"
report="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"

SELF_CHECK_TIMEOUT=300

# shellcheck source=lib-mac.sh
source "$(cd "$(dirname "$0")" && pwd)/lib-mac.sh"

echo "Installing $dmg"
install_dmg "$dmg" "$version"
app=$installed_app

echo "Checking the signature of $app"
codesign --verify --deep --strict --verbose=2 "$app" || fail "$app has no valid signature"
codesign -dvv "$app" 2>&1 | grep -F "Authority=$APP_ID signing" ||
    fail "$app is not signed with the $APP_ID signing certificate"
codesign -d -r- "$app" 2>&1 | grep -F "identifier \"$APP_ID\"" ||
    fail "the designated requirement of $app does not name $APP_ID"

echo "Running the self-check"
defaults write "$APP_ID" ApplePersistenceIgnoreState YES
exe=$(bundle_executable "$app")
code=0
run_with_timeout "$SELF_CHECK_TIMEOUT" "$exe" --self-check "--self-check-report=$report" || code=$?
[ -f "$report" ] || fail "the self-check wrote no report (exit code $code)"
check_report "$report" "$version"
[ "$code" -eq 0 ] || fail "the self-check exited with $code"
echo "Install test passed for $version"
