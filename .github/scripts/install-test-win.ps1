<#
.SYNOPSIS
Install test (Windows): runs the one-click installer silently, checks the per-user install location and version,
starts the installed app in self-check mode, checks the report and uninstalls.

.DESCRIPTION
Needs PowerShell 7.4 or later and python on PATH (see lib-win.ps1).

.EXAMPLE
./install-test-win.ps1 -Installer context-workspace-0.1.0-win-x64-setup.exe -Version 0.1.0 -Report reports/self-check.json
#>
param(
    [Parameter(Mandatory)] [string] $Installer,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Report
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UninstallTimeoutSeconds = 120

. (Join-Path $PSScriptRoot 'lib-win.ps1')

$Installer = (Resolve-Path $Installer).Path
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Report) | Out-Null
$Report = Join-Path (Resolve-Path (Split-Path -Parent $Report)).Path (Split-Path -Leaf $Report)

Write-Host "Installing $Installer"
$app = Install-App -Installer $Installer -Version $Version
Write-Host "Installed $($app.Exe)"

Write-Host 'Running the self-check'
$code = Invoke-Program -Path $app.Exe -Arguments @('--self-check', "--self-check-report=`"$Report`"")
if (-not (Test-Path $Report)) { Fail "the self-check wrote no report (exit code $code)" }
Assert-SelfCheckReport -Path $Report -ExpectedVersion $Version
if ($code -ne 0) { Fail "the self-check exited with $code" }

Write-Host 'Uninstalling'
$code = Invoke-Program -Path $app.Uninstaller -Arguments @('/currentuser', '/S')
Write-Host "The uninstaller returned $code"
# The uninstaller copies itself to %TEMP% and returns at once; the copy does the work.
$deadline = (Get-Date).AddSeconds($UninstallTimeoutSeconds)
while ((Test-Path $app.Exe) -or ($null -ne (Get-InstalledVersion))) {
    if ((Get-Date) -gt $deadline) { Fail "the app is still installed $UninstallTimeoutSeconds s after uninstalling" }
    Start-Sleep -Seconds 2
}
Write-Host "Install test passed for $Version"
