#!/usr/bin/env bash
# Tests lib-mac.sh, the helpers of the macOS install and update tests. Run on macOS:
# bash .github/scripts/lib-mac.test.sh
#
# The check_report tests also cover check-self-check-report.py, which the Windows tests use too. The fixture apps are
# small bundles around a copy of /usr/bin/true, signed ad hoc with an explicit designated requirement; nothing is
# installed in /Applications.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lib="$here/lib-mac.sh"
work=$(cd "$(mktemp -d)" && pwd -P) # physical path, as hdiutil info prints it
trap 'rm -rf "$work"' EXIT

# Runs <bash code> in a new shell with lib-mac.sh loaded and the options the test scripts use; the remaining
# arguments are $1, $2, ... there. A new shell keeps `exit` in `fail` and `set -e` working as they do in the scripts.
with_lib() { # <bash code> [args...]
    local code=$1
    shift
    bash -c "set -euo pipefail; source \"\$0\"; $code" "$lib" "$@"
}

# Writes an app bundle the way electron-builder lays one out: signed ad hoc with the designated requirement
# `identifier "<identifier>"`, or not signed at all when the identifier is empty.
make_app() { # <app path> <version> <identifier or empty>
    rm -rf "$1"
    mkdir -p "$1/Contents/MacOS"
    cp /usr/bin/true "$1/Contents/MacOS/fake"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string fake' \
        -c "Add :CFBundleShortVersionString string $2" \
        -c "Add :CFBundleIdentifier string ${3:-test.unsigned}" "$1/Contents/Info.plist" >/dev/null
    if [ -n "$3" ]; then
        codesign --sign - --force -r "=designated => identifier \"$3\"" "$1" 2>/dev/null
    else
        codesign --remove-signature "$1/Contents/MacOS/fake" # the copy keeps Apple's signature otherwise
    fi
}

# Writes a DMG holding one app bundle of <version>.
make_dmg() { # <dmg path> <version>
    local root="$work/dmg-root-$2"
    make_app "$root/Fake App.app" "$2" test.fake
    hdiutil create -quiet -fs HFS+ -srcfolder "$root" -volname 'Fake App' "$1"
}

write_report() { # <file> <json>
    printf '%s\n' "$2" >"$1"
}

failures=0
# Runs a test function, which prints nothing when the test passed. A test that stops early also fails.
run_test() { # <test name> <test function>
    local message status=0
    message=$("$2") || status=$?
    if [ "$status" -ne 0 ]; then message="the test stopped with exit code $status${message:+: $message}"; fi
    if [ -z "$message" ]; then
        echo "ok - $1"
    else
        echo "not ok - $1: $message"
        failures=$((failures + 1))
    fi
}

run_with_timeout_passes_the_exit_code_through() {
    local code=0
    with_lib 'run_with_timeout 5 sh -c "exit 7"' || code=$?
    [ "$code" -eq 7 ] || echo "exit code $code, expected 7"
}

run_with_timeout_stops_a_command_that_runs_too_long() {
    local code=0 start=$SECONDS output
    output=$(with_lib 'run_with_timeout 1 sleep 30') || code=$?
    if [ "$code" -ne 124 ]; then
        echo "exit code $code, expected 124"
    elif [ $((SECONDS - start)) -gt 10 ]; then
        echo "took $((SECONDS - start)) s"
    elif [[ "$output" != *'Timed out after 1 s: sleep 30'* ]]; then
        echo "no timeout message: $output"
    fi
}

check_report_passes_a_clean_report() {
    local code=0 output
    write_report "$work/clean.json" \
        '{"exitCode":0,"version":"1.2.3","results":[{"name":"engine","ok":true,"detail":"found"}]}'
    output=$(with_lib 'check_report "$1" 1.2.3' "$work/clean.json" 2>&1) || code=$?
    if [ "$code" -ne 0 ]; then
        echo "exit code $code: $output"
    elif [ "$output" != 'ok   engine: found' ]; then
        echo "unexpected output: $output"
    fi
}

check_report_fails_a_report_with_failed_checks() {
    local code=0 output
    write_report "$work/failed.json" \
        '{"exitCode":1,"version":"1.2.3","results":[{"name":"engine","ok":true,"detail":"found"},{"name":"git","ok":false,"detail":"missing"}]}'
    output=$(with_lib 'check_report "$1" 1.2.3; echo still running' "$work/failed.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'FAIL git: missing'* || "$output" != *'::error::self-check reported failures'* ]]; then
        echo "unexpected output: $output"
    elif [[ "$output" == *'still running'* ]]; then
        echo 'the script went on after the failure'
    fi
}

check_report_fails_a_report_of_another_version() {
    local code=0 output
    write_report "$work/old.json" '{"exitCode":0,"version":"1.2.2","results":[]}'
    output=$(with_lib 'check_report "$1" 1.2.3' "$work/old.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::self-check ran version 1.2.2, expected 1.2.3'* ]]; then
        echo "unexpected output: $output"
    fi
}

check_report_fails_a_report_that_is_not_json() {
    local code=0 output
    write_report "$work/broken.json" '{"exitCode":0,'
    output=$(with_lib 'check_report "$1" 1.2.3' "$work/broken.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::cannot read the self-check report'* ]]; then
        echo "unexpected output: $output"
    fi
}

# On Windows runners python writes to a pipe in the ANSI code page; a detail it cannot encode must not crash the check.
check_report_prints_details_the_output_encoding_cannot_hold() {
    local code=0 output
    write_report "$work/unicode.json" \
        '{"exitCode":0,"version":"1.2.3","results":[{"name":"map","ok":true,"detail":"café ✓"}]}'
    export PYTHONIOENCODING=ascii
    output=$(with_lib 'check_report "$1" 1.2.3' "$work/unicode.json" 2>&1) || code=$?
    [ "$code" -eq 0 ] || echo "exit code $code: $output"
}

check_manual_offer_passes_a_report_that_offers_the_update() {
    local code=0 output
    write_report "$work/manual.json" \
        '{"exitCode":15,"outcome":"manual-update-offered","version":"1.2.2","updateVersion":"1.2.3","detail":"Offers 1.2.3 for a download by hand: https://example.test/a.dmg"}'
    output=$(with_lib 'check_manual_offer "$1" 1.2.3' "$work/manual.json" 2>&1) || code=$?
    if [ "$code" -ne 0 ]; then
        echo "exit code $code: $output"
    elif [ "$output" != 'Offers 1.2.3 for a download by hand: https://example.test/a.dmg' ]; then
        echo "unexpected output: $output"
    fi
}

check_manual_offer_fails_a_report_of_another_update() {
    local code=0 output
    write_report "$work/manual-old.json" \
        '{"exitCode":15,"outcome":"manual-update-offered","version":"1.2.2","updateVersion":"1.2.4","detail":"x"}'
    output=$(with_lib 'check_manual_offer "$1" 1.2.3; echo still running' "$work/manual-old.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::the update test reported manual-update-offered for 1.2.4, expected manual-update-offered for 1.2.3'* ]]; then
        echo "unexpected output: $output"
    elif [[ "$output" == *'still running'* ]]; then
        echo 'the script went on after the failure'
    fi
}

check_manual_offer_fails_another_outcome() {
    local code=0 output
    write_report "$work/installing.json" \
        '{"exitCode":0,"outcome":"installing","version":"1.2.2","updateVersion":"1.2.3","detail":"x"}'
    output=$(with_lib 'check_manual_offer "$1" 1.2.3' "$work/installing.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::the update test reported installing for 1.2.3, expected manual-update-offered for 1.2.3'* ]]; then
        echo "unexpected output: $output"
    fi
}

check_signature_rejected_passes_a_report_that_rejects_the_update() {
    local code=0 output
    write_report "$work/rejected.json" \
        '{"exitCode":12,"outcome":"mac-signature-rejected","version":"1.2.2","updateVersion":"1.2.3","detail":"Code signature did not pass validation"}'
    output=$(with_lib 'check_signature_rejected "$1" 1.2.3' "$work/rejected.json" 2>&1) || code=$?
    if [ "$code" -ne 0 ]; then
        echo "exit code $code: $output"
    elif [ "$output" != 'Code signature did not pass validation' ]; then
        echo "unexpected output: $output"
    fi
}

check_signature_rejected_fails_another_outcome() {
    local code=0 output
    write_report "$work/native.json" \
        '{"exitCode":13,"outcome":"native-error","version":"1.2.2","updateVersion":"1.2.3","detail":"x"}'
    output=$(with_lib 'check_signature_rejected "$1" 1.2.3; echo still running' "$work/native.json" 2>&1) ||
        code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::the update test reported native-error for 1.2.3, expected mac-signature-rejected for 1.2.3'* ]]; then
        echo "unexpected output: $output"
    elif [[ "$output" == *'still running'* ]]; then
        echo 'the script went on after the failure'
    fi
}

check_signature_rejected_fails_a_report_of_another_update() {
    local code=0 output
    write_report "$work/rejected-other.json" \
        '{"exitCode":12,"outcome":"mac-signature-rejected","version":"1.2.2","updateVersion":"1.2.4","detail":"x"}'
    output=$(with_lib 'check_signature_rejected "$1" 1.2.3' "$work/rejected-other.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::the update test reported mac-signature-rejected for 1.2.4, expected mac-signature-rejected for 1.2.3'* ]]; then
        echo "unexpected output: $output"
    fi
}

check_signature_rejected_fails_without_a_report() {
    local code=0 output
    output=$(with_lib 'check_signature_rejected "$1" 1.2.3' "$work/missing.json" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::cannot read the update-test report'* ]]; then
        echo "unexpected output: $output"
    fi
}

install_dmg_copies_the_app_and_checks_its_version() {
    local code=0 output
    make_dmg "$work/install.dmg" 1.2.3
    mkdir -p "$work/Applications/Fake App.app/stale"
    output=$(with_lib 'install_dmg "$1" 1.2.3 "$2"; echo "installed_app=$installed_app"' \
        "$work/install.dmg" "$work/Applications" 2>&1) || code=$?
    if [ "$code" -ne 0 ]; then
        echo "exit code $code: $output"
    elif [ "$output" != "installed_app=$work/Applications/Fake App.app" ]; then
        echo "unexpected output: $output"
    elif [ ! -x "$work/Applications/Fake App.app/Contents/MacOS/fake" ]; then
        echo 'the app was not copied'
    elif [ -e "$work/Applications/Fake App.app/stale" ]; then
        echo 'the earlier copy was not replaced'
    elif hdiutil info | grep -qF "$work/install.dmg"; then
        echo 'the DMG is still attached'
    fi
}

install_dmg_fails_on_another_version() {
    local code=0 output
    make_dmg "$work/other.dmg" 1.2.2
    output=$(with_lib 'install_dmg "$1" 1.2.3 "$2"' "$work/other.dmg" "$work/Applications-other" 2>&1) || code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'::error::installed version is 1.2.2, expected 1.2.3'* ]]; then
        echo "unexpected output: $output"
    fi
}

check_designated_requirement_accepts_an_update_that_satisfies_it() {
    local code=0 output
    make_app "$work/dr/installed.app" 1.2.3 test.fake
    make_app "$work/dr/update.app" 1.2.4 test.fake
    output=$(with_lib 'check_designated_requirement "$1" "$2"' "$work/dr/installed.app" "$work/dr/update.app" 2>&1) ||
        code=$?
    [ "$code" -eq 0 ] || echo "exit code $code: $output"
}

check_designated_requirement_rejects_an_update_that_does_not_satisfy_it() {
    local code=0 output
    make_app "$work/dr/installed.app" 1.2.3 test.fake
    make_app "$work/dr/other.app" 1.2.4 test.other
    output=$(with_lib 'check_designated_requirement "$1" "$2"' "$work/dr/installed.app" "$work/dr/other.app" 2>&1) ||
        code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" == *'syntax error'* ]]; then
        echo "codesign could not read the requirement: $output"
    elif [[ "$output" != *'does not satisfy the designated requirement'*'identifier "test.fake"'* ]]; then
        echo "unexpected output: $output"
    fi
}

check_designated_requirement_fails_for_an_unsigned_app() {
    local code=0 output
    make_app "$work/dr/unsigned.app" 1.2.3 ''
    make_app "$work/dr/update.app" 1.2.4 test.fake
    output=$(with_lib 'check_designated_requirement "$1" "$2"' "$work/dr/unsigned.app" "$work/dr/update.app" 2>&1) ||
        code=$?
    if [ "$code" -ne 1 ]; then
        echo "exit code $code, expected 1: $output"
    elif [[ "$output" != *'has no designated requirement'* ]]; then
        echo "unexpected output: $output"
    fi
}

run_test 'run_with_timeout passes the exit code through' run_with_timeout_passes_the_exit_code_through
run_test 'run_with_timeout stops a command that runs too long' run_with_timeout_stops_a_command_that_runs_too_long
run_test 'check_report passes a clean report' check_report_passes_a_clean_report
run_test 'check_report fails a report with failed checks' check_report_fails_a_report_with_failed_checks
run_test 'check_report fails a report of another version' check_report_fails_a_report_of_another_version
run_test 'check_report fails a report that is not JSON' check_report_fails_a_report_that_is_not_json
run_test 'check_report prints details the output encoding cannot hold' \
    check_report_prints_details_the_output_encoding_cannot_hold
run_test 'check_manual_offer passes a report that offers the update' \
    check_manual_offer_passes_a_report_that_offers_the_update
run_test 'check_manual_offer fails a report of another update' check_manual_offer_fails_a_report_of_another_update
run_test 'check_manual_offer fails another outcome' check_manual_offer_fails_another_outcome
run_test 'check_signature_rejected passes a report that rejects the update' \
    check_signature_rejected_passes_a_report_that_rejects_the_update
run_test 'check_signature_rejected fails another outcome' check_signature_rejected_fails_another_outcome
run_test 'check_signature_rejected fails a report of another update' \
    check_signature_rejected_fails_a_report_of_another_update
run_test 'check_signature_rejected fails without a report' check_signature_rejected_fails_without_a_report
run_test 'install_dmg copies the app and checks its version' install_dmg_copies_the_app_and_checks_its_version
run_test 'install_dmg fails on another version' install_dmg_fails_on_another_version
run_test 'check_designated_requirement accepts an update that satisfies it' \
    check_designated_requirement_accepts_an_update_that_satisfies_it
run_test 'check_designated_requirement rejects an update that does not satisfy it' \
    check_designated_requirement_rejects_an_update_that_does_not_satisfy_it
run_test 'check_designated_requirement fails for an unsigned app' check_designated_requirement_fails_for_an_unsigned_app
exit $((failures > 0))
