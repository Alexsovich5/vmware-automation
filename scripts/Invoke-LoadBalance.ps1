<#
.SYNOPSIS
    Balances host memory load in the configured cluster with vMotion.
.DESCRIPTION
    Loads the settings file, imports VMwareAutomation and PowerCLI, connects to vCenter and
    runs Invoke-VALoadBalance with -Confirm:$false, so it never prompts when started by a
    scheduler. The plan follows the loadBalance section of the settings file. Prints one row
    per migration (Moved, or WouldMove under -WhatIf); prints nothing when the cluster is
    already balanced.
    Exit code: 0 on success; a failed migration stops the script with a non-zero exit code.
.EXAMPLE
    .\scripts\Invoke-LoadBalance.ps1 -ConfigPath .\config\settings.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$module = Import-Module (Join-Path $repoRoot 'src/VMwareAutomation/VMwareAutomation.psd1') -Global -Force -PassThru

$config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
& $module { Import-VAPowerCLI }
$server = Connect-VAvCenter -Config $config

try {
    $results = @(Invoke-VALoadBalance -Config $config -Confirm:$false -WhatIf:([bool]$WhatIfPreference))
}
finally {
    Disconnect-VIServer -Server $server -Confirm:$false -WhatIf:$false -ErrorAction SilentlyContinue
}

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize Order, VM, Source, Destination, SpreadBefore, SpreadAfter, Action |
        Out-String -Width 200 | Write-Output
}
else {
    Write-Output ('{0} is balanced; no migrations needed.' -f $config.cluster)
}
exit 0
