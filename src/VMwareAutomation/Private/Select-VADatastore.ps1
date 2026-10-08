function Select-VADatastore {
    <#
    .SYNOPSIS
        Picks the datastore for a new VM cloned from the given template onto the given host.
    .DESCRIPTION
        Only datastores mounted on the host are considered. A datastore qualifies when, after
        the template disk (provisioning.templates.<template>.diskGB) is taken, at least
        provisioning.datastoreReservePct of its capacity is still free. With -Datastore that
        datastore is checked and used; otherwise the qualifying datastore with the most free
        space wins (name breaks ties). Throws when nothing qualifies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [object]$VMHost,

        [Parameter(Mandatory=$true)]
        [string]$Template,

        [string]$Datastore
    )

    $hostName = [string]$VMHost
    if ($VMHost.PSObject.Properties['Name']) {
        $hostName = [string]$VMHost.Name
    }
    $diskGB = [double]$Config.provisioning.templates.$Template.diskGB
    $reservePct = [double]$Config.provisioning.datastoreReservePct

    $mounted = @(Get-Datastore -VMHost $VMHost)

    $keepsReserve = {
        param($ds)
        $capacity = [double]$ds.CapacityGB
        if ($capacity -le 0) { return $false }
        (([double]$ds.FreeSpaceGB - $diskGB) / $capacity * 100) -ge $reservePct
    }

    if ($Datastore) {
        $chosen = @($mounted | Where-Object { $_.Name -eq $Datastore })
        if ($chosen.Count -eq 0) {
            throw ("Datastore '{0}' is not available on host '{1}'." -f $Datastore, $hostName)
        }
        if (-not (& $keepsReserve $chosen[0])) {
            $leftPct = ([double]$chosen[0].FreeSpaceGB - $diskGB) / [double]$chosen[0].CapacityGB * 100
            throw ("Datastore '{0}' would fall below the {1}% free-space reserve ({2:N1}% left after {3} GB)." -f $Datastore, $reservePct, $leftPct, $diskGB)
        }
        return $chosen[0]
    }

    $qualifying = @($mounted | Where-Object { & $keepsReserve $_ })
    if ($qualifying.Count -eq 0) {
        throw ("Cannot place the VM: no datastore on host '{0}' can hold {1} GB and keep the {2}% free-space reserve." -f $hostName, $diskGB, $reservePct)
    }

    $qualifying | Sort-Object -Property @{ Expression = { [double]$_.FreeSpaceGB }; Descending = $true }, @{ Expression = { $_.Name }; Ascending = $true } |
        Select-Object -First 1
}
