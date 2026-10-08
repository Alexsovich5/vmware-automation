<#
.SYNOPSIS
    Loads the settings file, imports VMwareAutomation and PowerCLI, and connects to vCenter.
.DESCRIPTION
    The password comes from -Credential or from the environment variable named by
    vCenter.passwordEnv. Get-Credential is called only when neither is present.
.EXAMPLE
    .\config\Connect-vCenter.ps1 -ConfigPath .\config\settings.example.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,

    [System.Management.Automation.PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$module = Import-Module (Join-Path $repoRoot 'src/VMwareAutomation/VMwareAutomation.psd1') -Global -Force -PassThru

$config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
& $module { Import-VAPowerCLI }

if (-not $Credential) {
    $envName = $config.vCenter.passwordEnv
    if (-not [Environment]::GetEnvironmentVariable($envName)) {
        $Credential = Get-Credential -UserName $config.vCenter.user -Message ("Password for {0}" -f $config.vCenter.server)
    }
}

if ($Credential) {
    Connect-VAvCenter -Config $config -Credential $Credential
}
else {
    Connect-VAvCenter -Config $config
}
