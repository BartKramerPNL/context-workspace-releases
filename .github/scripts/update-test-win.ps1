<#
.SYNOPSIS
Update test (Windows): installs version N, serves version N+1 from a local feed, lets N update itself, waits for N+1
to be installed and self-checks it.

.DESCRIPTION
The feed directory holds the N+1 installer, its blockmap and latest.yml. The output directory receives the
update-test and self-check reports and the feed server logs. Needs PowerShell 7.4 or later and python on PATH
(see lib-win.ps1).

.EXAMPLE
./update-test-win.ps1 -FromInstaller n/context-workspace-0.1.0-win-x64-setup.exe -FromVersion 0.1.0 -Feed feed -ToVersion 0.1.1 -OutDir reports
#>
param(
    [Parameter(Mandatory)] [string] $FromInstaller,
    [Parameter(Mandatory)] [string] $FromVersion,
    [Parameter(Mandatory)] [string] $Feed,
    [Parameter(Mandatory)] [string] $ToVersion,
    [Parameter(Mandatory)] [string] $OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FeedPort = 8765
$FeedUrl = "http://127.0.0.1:$FeedPort/"
$InstallTimeoutSeconds = 180

. (Join-Path $PSScriptRoot 'lib-win.ps1')

function Get-UpdateExitMeaning([int] $Code) {
    switch ($Code) {
        10 { return 'no update found in the feed' }
        11 { return 'checking for or downloading the update failed' }
        13 { return 'native update error' }
        14 { return 'the app watchdog stopped the update test (240 s)' }
        default { return 'unexpected exit code' }
    }
}

$FromInstaller = (Resolve-Path $FromInstaller).Path
$Feed = (Resolve-Path $Feed).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

Write-Host "Installing version N ($FromVersion) from $FromInstaller"
$app = Install-App -Installer $FromInstaller -Version $FromVersion

Write-Host "Serving N+1 ($ToVersion) on $FeedUrl"
$server = Start-Process -FilePath 'python' -PassThru `
    -ArgumentList @('-m', 'http.server', "$FeedPort", '--bind', '127.0.0.1', '--directory', "`"$Feed`"") `
    -RedirectStandardOutput (Join-Path $OutDir 'feed-server.log') `
    -RedirectStandardError (Join-Path $OutDir 'feed-server-errors.log')
try {
    curl.exe -sf --retry 10 --retry-connrefused -o NUL "${FeedUrl}latest.yml"
    if ($LASTEXITCODE -ne 0) { Fail 'the local feed did not start' }

    Write-Host 'Running N in update-test mode'
    $updateReport = Join-Path $OutDir 'update-test.json'
    $code = Invoke-Program -Path $app.Exe -Arguments @('--update-test', "--update-test-report=`"$updateReport`"") `
        -Environment @{ CW_UPDATE_FEED_URL = $FeedUrl }
    if ($code -ne 0) { Fail "the update test exited with ${code}: $(Get-UpdateExitMeaning $code)" }

    Write-Host 'Waiting for the update to be installed'
    $deadline = (Get-Date).AddSeconds($InstallTimeoutSeconds)
    while ((Get-InstalledVersion) -ne $ToVersion) {
        if ((Get-Date) -gt $deadline) {
            Fail "after $InstallTimeoutSeconds s the installed version is '$(Get-InstalledVersion)', expected $ToVersion"
        }
        Start-Sleep -Seconds 5
    }
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}

Write-Host 'Running the self-check of N+1'
$app = Get-InstalledApp
$report = Join-Path $OutDir 'self-check-updated.json'
$code = Invoke-Program -Path $app.Exe -Arguments @('--self-check', "--self-check-report=`"$report`"")
if (-not (Test-Path $report)) { Fail "the self-check wrote no report (exit code $code)" }
Assert-SelfCheckReport -Path $report -ExpectedVersion $ToVersion
if ($code -ne 0) { Fail "the self-check exited with $code" }
Write-Host "Update test passed: $FromVersion -> $ToVersion"
