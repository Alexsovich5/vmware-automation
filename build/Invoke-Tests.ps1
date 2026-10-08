param(
    [string]$Path = 'test'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

Import-Module '/opt/Pester-2.0.4/Pester.psm1'

# 1. Static PowerShell 4 syntax gate over the shipped code.
$gatePaths = @(
    (Join-Path $root 'src'),
    (Join-Path $root 'scripts'),
    (Join-Path $root 'config/*.ps1'),
    (Join-Path $root 'simulator')
)
& (Join-Path $root 'build/Test-PS4Syntax.ps1') -Path $gatePaths
if ($LASTEXITCODE -ne 0) {
    Write-Output 'PS4 syntax gate failed.'
    exit 1
}

# 2. Pester 2.0.4 only discovers *.tests.ps1 (case-sensitive on Linux).
$testRoot = Join-Path $root 'test'
if (Test-Path $testRoot) {
    $miscased = @(Get-ChildItem -Path $testRoot -Recurse -File |
        Where-Object { $_.Name -like '*.tests.ps1' -and $_.Name -cnotlike '*.tests.ps1' })
    if ($miscased.Count -gt 0) {
        foreach ($file in $miscased) {
            Write-Output ('{0}: test file must be named *.tests.ps1 in lowercase' -f $file.FullName)
        }
        exit 1
    }
}

# 3. Run the tests; the exit code is the number of failed tests.
Invoke-Pester -Path $Path -EnableExit
