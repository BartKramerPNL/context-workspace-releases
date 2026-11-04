<#
.SYNOPSIS
Helpers shared by install-test-win.ps1 and update-test-win.ps1.

.DESCRIPTION
Dot-source it after Set-StrictMode: . (Join-Path $PSScriptRoot 'lib-win.ps1')
Needs PowerShell 7.4 or later (Start-Process -Environment) and python on PATH (check-self-check-report.py, which the
macOS tests use too).
#>

$AppId = 'app.contextworkspace.desktop'
# package.json `name`, which never changes.
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\context-workspace'
$AppTimeoutSeconds = 300
$SelfCheckReportChecker = Join-Path $PSScriptRoot 'check-self-check-report.py'

function Fail([string] $Message) {
    Write-Host "::error::$Message"
    exit 1
}

# electron-builder names the uninstall registry key after the RFC 4122 UUIDv5 of the app ID in its own namespace.
function Get-UninstallKey {
    $namespace = [Convert]::FromHexString('50e065bc313411e69bab38c9862bdaf3')
    $hash = [Security.Cryptography.SHA1]::HashData([byte[]] ($namespace + [Text.Encoding]::UTF8.GetBytes($AppId)))
    $hash[6] = ($hash[6] -band 0x0f) -bor 0x50
    $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
    $hex = [Convert]::ToHexString($hash, 0, 16).ToLowerInvariant()
    $guid = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
    return "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
}

# Returns $null while the key or its DisplayVersion value does not exist.
function Get-InstalledVersion {
    try {
        return Get-ItemPropertyValue -Path (Get-UninstallKey) -Name DisplayVersion
    } catch {
        return $null
    }
}

# The app executable is <productFilename>.exe next to `Uninstall <productFilename>.exe`.
function Get-InstalledApp {
    if (-not (Test-Path $InstallDir)) { Fail "nothing is installed in $InstallDir" }
    $uninstallers = @(Get-ChildItem -Path $InstallDir -Filter 'Uninstall *.exe')
    if ($uninstallers.Count -ne 1) { Fail "expected one uninstaller in $InstallDir, found $($uninstallers.Count)" }
    $exe = Join-Path $InstallDir ($uninstallers[0].Name -replace '^Uninstall ', '')
    if (-not (Test-Path $exe)) { Fail "no app executable at $exe" }
    return [pscustomobject] @{ Exe = $exe; Uninstaller = $uninstallers[0].FullName }
}

# Starts a program and waits for it (not for the processes it starts). Returns its exit code.
function Invoke-Program([string] $Path, [string[]] $Arguments, [hashtable] $Environment = @{}) {
    $options = @{ FilePath = $Path; ArgumentList = $Arguments; PassThru = $true }
    if ($Environment.Count -gt 0) { $options.Environment = $Environment }
    $process = Start-Process @options
    $null = $process.Handle # keeps the exit code readable after the process has exited
    if (-not $process.WaitForExit($AppTimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Fail "$Path did not exit within $AppTimeoutSeconds s"
    }
    return $process.ExitCode
}

# Runs the one-click installer silently and checks the installed version. Returns the app (see Get-InstalledApp).
function Install-App([string] $Installer, [string] $Version) {
    $code = Invoke-Program -Path $Installer -Arguments @('/S')
    if ($code -ne 0) { Fail "the installer exited with $code" }
    $installed = Get-InstalledVersion
    if ($installed -ne $Version) {
        Fail "the uninstall registry key $(Get-UninstallKey) holds version '$installed', expected $Version"
    }
    return Get-InstalledApp
}

# Prints the self-check results; fails unless all checks passed in the expected version.
function Assert-SelfCheckReport([string] $Path, [string] $ExpectedVersion) {
    & python $SelfCheckReportChecker $Path $ExpectedVersion
    if ($LASTEXITCODE -ne 0) { exit 1 } # the checker has printed the error
}
