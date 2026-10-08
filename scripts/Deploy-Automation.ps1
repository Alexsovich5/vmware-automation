<#
.SYNOPSIS
    Validates the settings and hardening baseline, then installs the VMwareAutomation module.
.DESCRIPTION
    Loads the settings file and the hardening baseline it names; if either is missing or
    invalid the script stops before copying anything. It then copies src/VMwareAutomation
    to <Destination>/VMwareAutomation (by default the first entry in $env:PSModulePath),
    imports the module by name from there and checks that its commands are exported.
    Registering scheduled jobs is left to the operator.
    Exit code: 0 when the module was installed and imports; 1 on any failure.
.EXAMPLE
    .\scripts\Deploy-Automation.ps1 -ConfigPath .\config\settings.json
.EXAMPLE
    .\scripts\Deploy-Automation.ps1 -ConfigPath .\config\settings.json -Destination C:\Modules
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,

    [string]$Destination
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repoRoot 'src/VMwareAutomation'
$moduleName = 'VMwareAutomation'

try {
    # 1. Config and baseline must load before anything is installed.
    $sourceModule = Import-Module (Join-Path $source 'VMwareAutomation.psd1') -Force -PassThru
    $config = & $sourceModule { param($Path) Read-VAConfig -Path $Path } $ConfigPath
    $null = & $sourceModule { param($Config) Read-VAHardeningBaseline -Config $Config } $config
    Remove-Module -Name $moduleName -Force
    Write-Output ('Config OK: {0}' -f $config.ConfigPath)
    Write-Output ('Baseline OK: {0}' -f $config.hardeningBaseline)

    # 2. Copy the module into the target module directory.
    $separator = [System.IO.Path]::PathSeparator
    if (-not $Destination) {
        $Destination = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { $_ })[0]
    }
    if (-not $Destination) {
        throw 'No -Destination given and $env:PSModulePath is empty.'
    }
    $Destination = [System.IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $target = Join-Path $Destination $moduleName
    if (Test-Path -Path $target) {
        Remove-Item -Path $target -Recurse -Force
    }
    Copy-Item -Path $source -Destination $target -Recurse -Force
    Write-Output ('Copied {0} to {1}' -f $source, $target)

    # 3. Import by name from the destination, as a scheduled job would.
    $paths = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { $_ })
    if (-not ($paths -contains $Destination)) {
        $env:PSModulePath = $Destination + $separator + $env:PSModulePath
    }
    $installed = Import-Module -Name $moduleName -Force -PassThru
    if ([System.IO.Path]::GetFullPath($installed.ModuleBase).TrimEnd('/', '\') -ne $target.TrimEnd('/', '\')) {
        throw ('Import-Module {0} loaded {1} instead of {2}' -f $moduleName, $installed.ModuleBase, $target)
    }
    $commands = @(Get-Command -Module $moduleName)
    if ($commands.Count -eq 0) {
        throw ('Module {0} exports no commands' -f $moduleName)
    }
    Write-Output ('Import-Module {0} OK from {1}: {2} commands exported' -f $moduleName, $installed.ModuleBase, $commands.Count)
}
catch {
    Write-Output ('Deploy failed: {0}' -f $_.Exception.Message)
    exit 1
}
exit 0
