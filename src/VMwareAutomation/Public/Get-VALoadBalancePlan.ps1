function Get-VALoadBalancePlan {
    <#
    .SYNOPSIS
        Builds a greedy vMotion plan that narrows the memory load spread between cluster hosts.
    .DESCRIPTION
        Host load is memory only: MemoryUsageGB / MemoryTotalGB of each connected host in the
        config's cluster, as Get-VMHost reports it. CPU load is not considered.
        While the spread (most loaded minus least loaded host, in percent) is above
        loadBalance.thresholdPct and fewer than loadBalance.maxMigrations moves are planned, the
        smallest powered-on VM on the most loaded host (name breaks ties) is moved to the least
        loaded host, provided that VM is not in loadBalance.excludeVMs, the move lowers the
        spread, and the destination stays at or below loadBalance.destMaxMemoryPct. When no VM
        qualifies the plan ends. Nothing is changed; the plan is returned as rows (Order, VM,
        MemoryGB, Source, Destination, SpreadBefore, SpreadAfter), spreads rounded half away from zero to 2 places.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config
    )

    $settings = $Config.loadBalance
    $threshold = [double]$settings.thresholdPct
    $maxMigrations = [int]$settings.maxMigrations
    $destMaxPct = [double]$settings.destMaxMemoryPct
    $excluded = @()
    if ($settings.PSObject.Properties['excludeVMs']) {
        $excluded = @($settings.excludeVMs | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }

    # Working copy of host memory, updated as moves are planned.
    $used = @{}
    $total = @{}
    foreach ($vmHost in @(Get-VMHost -Location $Config.cluster | Where-Object { "$($_.ConnectionState)" -eq 'Connected' })) {
        $name = [string]$vmHost.Name
        $used[$name] = [double]$vmHost.MemoryUsageGB
        $total[$name] = [double]$vmHost.MemoryTotalGB
    }
    if ($total.Count -lt 2) {
        Write-VALog -Config $Config -Message ('Load balance: {0} connected host(s) in {1}, nothing to balance' -f $total.Count, $Config.cluster)
        return
    }

    $candidates = @()
    foreach ($vm in @(Get-VM -Location $Config.cluster)) {
        $vmName = [string]$vm.Name
        if ("$($vm.PowerState)" -ne 'PoweredOn' -or $excluded -contains $vmName -or -not $vm.VMHost) {
            continue
        }
        $candidates += New-Object psobject -Property @{
            Name     = $vmName
            Host     = [string]$vm.VMHost.Name
            MemoryGB = [double]$vm.MemoryGB
        }
    }

    $getPct = {
        param([string]$HostName, [hashtable]$Used)
        100 * $Used[$HostName] / $total[$HostName]
    }
    $getSpread = {
        param([hashtable]$Used)
        $values = @($total.Keys | ForEach-Object { & $getPct $_ $Used } | Sort-Object)
        $values[-1] - $values[0]
    }

    $order = 0
    $moved = @()
    while ($order -lt $maxMigrations) {
        $spread = & $getSpread $used
        if ($spread -le $threshold) {
            break
        }
        $ranked = @($total.Keys | Sort-Object @{ Expression = { & $getPct $_ $used } }, @{ Expression = { $_ } })
        $source = $ranked[-1]
        $destination = $ranked[0]

        $choice = $null
        $choiceSpread = $null
        $onSource = @($candidates | Where-Object { $_.Host -eq $source -and $moved -notcontains $_.Name } |
            Sort-Object MemoryGB, Name)
        foreach ($candidate in $onSource) {
            $trial = $used.Clone()
            $trial[$source] -= $candidate.MemoryGB
            $trial[$destination] += $candidate.MemoryGB
            if ((& $getPct $destination $trial) -gt $destMaxPct) {
                continue
            }
            $trialSpread = & $getSpread $trial
            if ($trialSpread -lt $spread) {
                $choice = $candidate
                $choiceSpread = $trialSpread
                break
            }
        }
        if (-not $choice) {
            Write-VALog -Config $Config -Message ('Load balance: no VM on {0} can move to {1} and narrow the {2:N2}% spread' -f $source, $destination, $spread)
            break
        }

        $order++
        $used[$source] -= $choice.MemoryGB
        $used[$destination] += $choice.MemoryGB
        $choice.Host = $destination
        $moved += $choice.Name
        Write-VALog -Config $Config -Message ('Load balance plan {0}: {1} ({2} GB) {3} -> {4}, spread {5:N2}% -> {6:N2}%' -f
            $order, $choice.Name, $choice.MemoryGB, $source, $destination, $spread, $choiceSpread)
        New-Object psobject -Property ([ordered]@{
            Order        = $order
            VM           = $choice.Name
            MemoryGB     = $choice.MemoryGB
            Source       = $source
            Destination  = $destination
            SpreadBefore = [math]::Round($spread, 2, [MidpointRounding]::AwayFromZero)
            SpreadAfter  = [math]::Round($choiceSpread, 2, [MidpointRounding]::AwayFromZero)
        })
    }
}
