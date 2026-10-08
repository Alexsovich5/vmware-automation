<#
.SYNOPSIS
    Applies the snapshot policies from the settings file: new auto snapshots, pruning, stale report.
.DESCRIPTION
    Loads the settings file, imports VMwareAutomation and PowerCLI, connects to vCenter and
    runs Invoke-VASnapshotPolicy with -Confirm:$false, so it never prompts when started by a
    scheduler. -Now is passed through when given. Prints one row per snapshot created,
    removed or reported as stale.
    Exit code: 0 on success; any error (unknown policy, failed snapshot call) stops the
    script with a non-zero exit code.
.EXAMPLE
    .\scripts\Invoke-SnapshotRotation.ps1 -ConfigPath .\config\settings.json -PolicyName daily -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,

    [string]$PolicyName,

    [datetime]$Now
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$module = Import-Module (Join-Path $repoRoot 'src/VMwareAutomation/VMwareAutomation.psd1') -Global -Force -PassThru

$config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
& $module { Import-VAPowerCLI }
$server = Connect-VAvCenter -Config $config

$policyArgs = @{ Config = $config }
if ($PolicyName) {
    $policyArgs['PolicyName'] = $PolicyName
}
if ($PSBoundParameters.ContainsKey('Now')) {
    $policyArgs['Now'] = $Now
}

try {
    $results = @(Invoke-VASnapshotPolicy @policyArgs -Confirm:$false -WhatIf:([bool]$WhatIfPreference))
}
finally {
    Disconnect-VIServer -Server $server -Confirm:$false -WhatIf:$false -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize Policy, VM, Snapshot, Action | Out-String -Width 200 | Write-Output
exit 0
