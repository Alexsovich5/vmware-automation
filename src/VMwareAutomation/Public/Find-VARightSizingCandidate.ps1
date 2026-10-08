function Find-VARightSizingCandidate {
    <#
    .SYNOPSIS
        Flags oversized and undersized VMs from their Get-Stat history and suggests a size.
    .DESCRIPTION
        Reads cpu.usage.average and mem.usage.average for the powered-on VMs of the config's
        cluster over the last -Days days (default rightsizing.days) up to -Now (default
        Get-VANow). VMs with no samples are skipped. Rules, with thresholds from rightsizing:
          CPU oversized    avg < cpuLowAvgPct and peak < cpuLowPeakPct -> max(1, ceil(NumCpu / 2))
          memory oversized avg < memLowAvgPct -> max(minMemoryMB, MemoryMB / 2)
          CPU undersized   avg > cpuHighAvgPct -> min(NumCpu + 1, provisioning.limits.maxCpu)
          memory undersized avg > memHighAvgPct -> min(MemoryMB x 1.5, provisioning.limits.maxMemoryMB)
        Memory suggestions are rounded down to a multiple of 4 MB. A VM is Undersized when any
        undersized rule applies, otherwise Oversized when any oversized rule applies; a
        dimension no rule touches keeps its current value. Only flagged VMs are returned.
        Nothing is changed: the result is a recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [int]$Days,

        [datetime]$Now
    )

    if (-not $PSBoundParameters.ContainsKey('Days')) {
        $Days = [int]$Config.rightsizing.days
    }
    if (-not $PSBoundParameters.ContainsKey('Now')) {
        $Now = Get-VANow
    }
    $rules = $Config.rightsizing
    $limits = $Config.provisioning.limits
    $cpuMetric = 'cpu.usage.average'
    $memMetric = 'mem.usage.average'

    $vms = @(Get-VM -Location $Config.cluster | Where-Object { "$($_.PowerState)" -eq 'PoweredOn' })
    if ($vms.Count -eq 0) {
        Write-VALog -Config $Config -Message 'No powered-on VMs to check'
        return
    }

    $start = $Now.AddDays(-1 * $Days)
    $samples = @(Get-Stat -Entity $vms -Stat @($cpuMetric, $memMetric) -Start $start -Finish $Now)
    $summary = @{}
    foreach ($row in @(Get-VAStatSummary -Sample $samples)) {
        $summary['{0}|{1}' -f $row.Entity, $row.MetricId] = $row
    }

    $round = {
        param([double]$Value)
        [double][math]::Round([decimal]$Value, 2, [System.MidpointRounding]::AwayFromZero)
    }
    $toMultipleOf4 = {
        param([double]$Value)
        [int]([math]::Floor($Value / 4) * 4)
    }

    foreach ($vm in $vms) {
        $name = [string]$vm.Name
        $cpu = $summary['{0}|{1}' -f $name, $cpuMetric]
        $mem = $summary['{0}|{1}' -f $name, $memMetric]
        if (-not $cpu -and -not $mem) {
            Write-VALog -Config $Config -Message ("Skipping {0}: no samples since {1:yyyy-MM-dd HH:mm}" -f $name, $start)
            continue
        }

        $numCpu = [int]$vm.NumCpu
        $memoryMB = [int]$vm.MemoryMB
        $recCpu = $numCpu
        $recMem = $memoryMB
        $oversized = $false
        $undersized = $false

        if ($cpu) {
            if ($cpu.Average -gt [double]$rules.cpuHighAvgPct) {
                $undersized = $true
                $recCpu = [math]::Min($numCpu + 1, [int]$limits.maxCpu)
            }
            elseif ($cpu.Average -lt [double]$rules.cpuLowAvgPct -and $cpu.Maximum -lt [double]$rules.cpuLowPeakPct) {
                $oversized = $true
                $recCpu = [int][math]::Max(1, [math]::Ceiling($numCpu / 2))
            }
        }
        if ($mem) {
            if ($mem.Average -gt [double]$rules.memHighAvgPct) {
                $undersized = $true
                $recMem = & $toMultipleOf4 ([math]::Min($memoryMB * 1.5, [double]$limits.maxMemoryMB))
            }
            elseif ($mem.Average -lt [double]$rules.memLowAvgPct) {
                $oversized = $true
                $recMem = & $toMultipleOf4 ([math]::Max([double]$rules.minMemoryMB, $memoryMB / 2))
            }
        }

        if (-not $oversized -and -not $undersized) {
            continue
        }
        $recommendation = 'Oversized'
        if ($undersized) {
            $recommendation = 'Undersized'
        }

        $cpuAvg = $null
        $cpuPeak = $null
        $memAvg = $null
        if ($cpu) {
            $cpuAvg = & $round $cpu.Average
            $cpuPeak = & $round $cpu.Maximum
        }
        if ($mem) {
            $memAvg = & $round $mem.Average
        }

        Write-VALog -Config $Config -Message ("{0} is {1}: {2} vCPU/{3} MB -> {4} vCPU/{5} MB" -f $name, $recommendation, $numCpu, $memoryMB, $recCpu, $recMem)
        New-Object psobject -Property ([ordered]@{
            VM                  = $name
            NumCpu              = $numCpu
            MemoryMB            = $memoryMB
            CpuAvgPct           = $cpuAvg
            CpuPeakPct          = $cpuPeak
            MemAvgPct           = $memAvg
            Recommendation      = $recommendation
            RecommendedNumCpu   = [int]$recCpu
            RecommendedMemoryMB = [int]$recMem
        })
    }
}
