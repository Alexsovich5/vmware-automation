function Test-VAVMRequest {
    <#
    .SYNOPSIS
        Checks a provisioning request against the naming rule, the template catalogue, the
        vCPU and memory limits and the existing inventory.
    .DESCRIPTION
        Throws a message naming the first rule the request breaks; returns $true otherwise.
        Rules: name matches ^[a-z0-9-]{3,15}$, the template is listed under
        provisioning.templates, NumCpu and MemoryMB are inside provisioning.limits, MemoryMB is
        a multiple of 4, and no VM with that name exists (Get-VM).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [string]$Template,

        [Parameter(Mandatory=$true)]
        [int]$NumCpu,

        [Parameter(Mandatory=$true)]
        [long]$MemoryMB
    )

    if ($Name -cnotmatch '^[a-z0-9-]{3,15}$') {
        throw ("Invalid VM name '{0}': use 3 to 15 lowercase letters, digits or hyphens." -f $Name)
    }

    $templates = $Config.provisioning.templates
    if (-not $templates -or -not $templates.PSObject.Properties[$Template]) {
        throw ("Unknown template '{0}': it is not listed in provisioning.templates." -f $Template)
    }

    $limits = $Config.provisioning.limits
    if ($NumCpu -lt [int]$limits.minCpu -or $NumCpu -gt [int]$limits.maxCpu) {
        throw ("NumCpu {0} is outside the allowed range {1}-{2}." -f $NumCpu, $limits.minCpu, $limits.maxCpu)
    }
    if ($MemoryMB -lt [long]$limits.minMemoryMB -or $MemoryMB -gt [long]$limits.maxMemoryMB) {
        throw ("MemoryMB {0} is outside the allowed range {1}-{2}." -f $MemoryMB, $limits.minMemoryMB, $limits.maxMemoryMB)
    }
    if ($MemoryMB % 4 -ne 0) {
        throw ("MemoryMB {0} is not a multiple of 4." -f $MemoryMB)
    }

    $existing = @(Get-VM -Name $Name -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        throw ("A VM named '{0}' already exists." -f $Name)
    }

    $true
}
