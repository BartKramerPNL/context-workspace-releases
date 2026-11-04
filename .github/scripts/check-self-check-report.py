"""Checks the report the app writes with `--self-check --self-check-report=<path>`.

Prints every result and exits 1 unless the report says all checks passed in the expected version. The report shape
comes from the app: {"exitCode": 0 | 1, "version": "X.Y.Z", "results": [{"name", "ok", "detail"}]}. This file is the
only place the release tests read the report: lib-mac.sh and lib-win.ps1 both call it.

Usage: python3 check-self-check-report.py <report> <expected version>
"""
import json
import sys


def main(argv):
    if len(argv) != 3:
        print('usage: check-self-check-report.py <report> <expected version>', file=sys.stderr)
        return 2
    path, expected = argv[1], argv[2]
    # On Windows, python writes to a pipe in the ANSI code page, which cannot hold every character a detail may have.
    # The Actions log reads UTF-8.
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    try:
        with open(path, encoding='utf-8-sig') as f:
            report = json.load(f)
    except (OSError, ValueError) as error:
        print('::error::cannot read the self-check report %s: %s' % (path, error))
        return 1
    if not isinstance(report, dict):
        print('::error::the self-check report %s is not a JSON object' % path)
        return 1
    for result in report.get('results') or []:
        print('%s %s: %s' % ('ok  ' if result.get('ok') else 'FAIL', result.get('name'), result.get('detail')))
    if report.get('exitCode') != 0:
        print('::error::self-check reported failures')
        return 1
    if report.get('version') != expected:
        print('::error::self-check ran version %s, expected %s' % (report.get('version'), expected))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
