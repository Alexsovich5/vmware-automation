<#
.SYNOPSIS
    Provisions and deprovisions VMs from a request CSV and writes a result CSV.
.DESCRIPTION
    Loads the settings file, imports VMwareAutomation and PowerCLI, connects to vCenter and
    runs Invoke-VAProvisioningBatch with -Confirm:$false, so it never prompts when run
    non-interactively. The result CSV goes to the config's outputDir.
    Exit code: 0 when every row succeeded or was skipped, 1 when any row failed.
.EXAMPLE
    .\scripts\Invoke-Provisioning.ps1 -ConfigPath .\config\settings.json -RequestPath .\config\requests.example.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,

    [Parameter(Mandatory=$true)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$module = Import-Module (Join-Path $repoRoot 'src/VMwareAutomation/VMwareAutomation.psd1') -Global -Force -PassThru

$config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
& $module { Import-VAPowerCLI }
$server = Connect-VAvCenter -Config $config

try {
    $results = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $RequestPath -Confirm:$false -WhatIf:([bool]$WhatIfPreference))
}
finally {
    Disconnect-VIServer -Server $server -Confirm:$false -WhatIf:$false -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize Action, Name, Status, Host, Datastore, Message | Out-String -Width 200 | Write-Output

if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
    exit 1
}
exit 0
