# Helpers shared by install-test-mac.sh and update-test-mac.sh. Load with: source "<scripts dir>/lib-mac.sh"
# The scripts set `set -euo pipefail` first. Works with bash 3.2. Tested by lib-mac.test.sh.

APP_ID=app.contextworkspace.desktop
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fail() {
    echo "::error::$*"
    exit 1
}

# Runs a command, killing it after <seconds>. Returns the command's exit code, or 124 on a timeout.
run_with_timeout() { # <seconds> <command> [args...]
    local seconds=$1 waited=0 pid
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$seconds" ]; then
            echo "Timed out after ${seconds} s: $*"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Prints the self-check results; fails unless all checks passed in the expected version. The report check itself is
# check-self-check-report.py, which the Windows tests use too.
check_report() { # <report> <expected version>
    python3 "$LIB_DIR/check-self-check-report.py" "$1" "$2" || exit 1
}

# Fails unless the update-test report (written by --update-test) has <outcome> for the update <version>; prints the
# report's detail.
check_update_report() { # <update-test report> <expected outcome> <expected update version>
    local output
    output=$(
        python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, outcome, version = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as file:
        report = json.load(file)
except (OSError, ValueError) as error:
    print(f"cannot read the update-test report: {error}")
    sys.exit(1)
if report.get("outcome") != outcome or report.get("updateVersion") != version:
    print(
        f"the update test reported {report.get('outcome')} for {report.get('updateVersion')},"
        f" expected {outcome} for {version}"
    )
    sys.exit(1)
print(report.get("detail", ""))
PY
    ) || fail "$output"
    echo "$output"
}

# With MAC_SILENT_UPDATES false, version N only offers the update for a download by hand (--update-test exit code
# 15). Fails unless the update-test report says it offered <expected version>; prints the report's detail.
check_manual_offer() { # <update-test report> <expected version>
    check_update_report "$1" manual-update-offered "$2"
}

# The release that switches MAC_SILENT_UPDATES off: version N, built with silent updates on, still installs through
# Squirrel.Mac, which rejects the update (exit code 12); N then shows the banner that links to the DMG. Fails unless
# the update-test report says macOS rejected the signature of <expected version>; prints the report's detail.
check_signature_rejected() { # <update-test report> <expected version>
    check_update_report "$1" mac-signature-rejected "$2"
}

bundle_version() { # <app>
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"
}

# Prints the path of the app's executable. Assign it to a variable first: a failure inside $(…) does not stop the script.
bundle_executable() { # <app>
    local name
    name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist") || return 1
    echo "$1/Contents/MacOS/$name"
}

# Installs the app the way a user does: copies the one .app in the DMG to the applications folder, replacing an
# earlier copy, and checks its version. Sets installed_app to the installed bundle.
install_dmg() { # <dmg> <expected version> [<applications dir, default /Applications>]
    local mount apps installed
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$1" >/dev/null
    apps=("$mount"/*.app)
    if [ "${#apps[@]}" -ne 1 ] || [ ! -d "${apps[0]}" ]; then
        hdiutil detach "$mount" -quiet || true
        fail "expected one .app in $1"
    fi
    installed_app="${3:-/Applications}/$(basename "${apps[0]}")"
    rm -rf "$installed_app"
    ditto "${apps[0]}" "$installed_app"
    hdiutil detach "$mount" -quiet
    rmdir "$mount" 2>/dev/null || true
    installed=$(bundle_version "$installed_app")
    [ "$installed" = "$2" ] || fail "installed version is $installed, expected $2"
}

# Squirrel.Mac installs an update only if it satisfies the designated requirement of the running app. Checking that
# before the update test gives a clear error when the certificate or the app ID changed between the two versions.
check_designated_requirement() { # <installed app> <update app>
    local requirement code=0
    requirement=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p') || true
    [ -n "$requirement" ] || fail "$1 has no designated requirement (is it signed with the certificate?)"
    # -R takes the requirement as its own argument; a leading "=" marks it as requirement text rather than a file.
    # (-R="=…" would hand codesign "==…", a syntax error.) Exit code 3 means the requirement is not satisfied.
    codesign --verify --deep --strict -R "=$requirement" "$2" || code=$?
    case $code in
    0) ;;
    3) fail "$2 does not satisfy the designated requirement of $1 ($requirement); did the certificate or the app ID change?" ;;
    *) fail "codesign could not check $2 against the designated requirement of $1 (exit code $code)" ;;
    esac
}
