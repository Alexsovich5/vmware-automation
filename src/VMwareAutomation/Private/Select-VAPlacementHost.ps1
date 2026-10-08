function Select-VAPlacementHost {
    <#
    .SYNOPSIS
        Picks the host for a new VM of the given memory size.
    .DESCRIPTION
        Considers the cluster's hosts that are Connected (not in maintenance, disconnected or
        not responding) and whose projected memory load, (MemoryUsageGB * 1024 + MemoryMB) /
        (MemoryTotalGB * 1024), stays at or below provisioning.hostMaxMemoryPct. The host with
        the lowest current memory load wins; the host name breaks ties. Throws when no host fits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [long]$MemoryMB,

        [string]$Cluster
    )

    if (-not $Cluster) {
        $Cluster = $Config.cluster
    }
    $maxPct = [double]$Config.provisioning.hostMaxMemoryPct

    $candidates = @()
    foreach ($vmHost in @(Get-VMHost -Location $Cluster)) {
        if ("$($vmHost.ConnectionState)" -ne 'Connected') {
            continue
        }
        $totalMB = [double]$vmHost.MemoryTotalGB * 1024
        if ($totalMB -le 0) {
            continue
        }
        $usedMB = [double]$vmHost.MemoryUsageGB * 1024
        $projectedPct = ($usedMB + $MemoryMB) / $totalMB * 100
        if ($projectedPct -gt $maxPct) {
            continue
        }
        $candidates += New-Object psobject -Property @{
            Host    = $vmHost
            Name    = [string]$vmHost.Name
            LoadPct = $usedMB / $totalMB * 100
        }
    }

    if ($candidates.Count -eq 0) {
        throw ("Cannot place the VM: no host has capacity for {0} MB in cluster '{1}' within {2}% memory." -f $MemoryMB, $Cluster, $maxPct)
    }

    ($candidates | Sort-Object -Property LoadPct, Name | Select-Object -First 1).Host
}
