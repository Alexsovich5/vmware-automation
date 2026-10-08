function Get-VAPerformanceAlert {
    <#
    .SYNOPSIS
        Compares recent performance samples and datastore free space with the alert thresholds.
    .DESCRIPTION
        For the hosts and powered-on VMs of the config's cluster, reads the last alerts.samples
        realtime samples (Get-Stat -Realtime -MaxSamples) up to -Now (default Get-VANow) for
        each metric named under alerts.host and alerts.vm, and averages them. An average at or
        above crit is Critical, at or above warn is a Warning; each entity and metric gets only
        its highest severity. Datastores mounted on the cluster's hosts are checked on free
        space: at or below datastoreFreePct.crit is Critical, at or below .warn is a Warning.
        Missing data is not treated as healthy: a host (in any connection state) or powered-on
        VM that returns no sample for a configured metric gets an Unknown row for that metric,
        and a cluster with no hosts gets one Unknown row (EntityType Cluster, Metric hosts).
        Unknown rows have no Value and no Threshold.
        Returns rows (Severity, EntityType, Entity, Metric, Value, Threshold, Timestamp), with
        Value rounded to two decimals and Timestamp set to the evaluation time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [datetime]$Now
    )

    if (-not $PSBoundParameters.ContainsKey('Now')) {
        $Now = Get-VANow
    }
    $alerts = $Config.alerts
    $samples = [int]$alerts.samples
    if ($samples -lt 1) {
        $samples = 1
    }

    $round = {
        param([double]$Value)
        [double][math]::Round([decimal]$Value, 2, [System.MidpointRounding]::AwayFromZero)
    }
    $newAlert = {
        param([string]$Severity, [string]$EntityType, [string]$Entity, [string]$Metric, [object]$Value, [object]$Threshold)
        New-Object psobject -Property ([ordered]@{
            Severity   = $Severity
            EntityType = $EntityType
            Entity     = $Entity
            Metric     = $Metric
            Value      = $Value
            Threshold  = $Threshold
            Timestamp  = $Now
        })
    }

    $rows = @()
    $hosts = @(Get-VMHost -Location $Config.cluster)
    $vms = @(Get-VM -Location $Config.cluster | Where-Object { "$($_.PowerState)" -eq 'PoweredOn' })
    if ($hosts.Count -eq 0) {
        Write-VALog -Config $Config -Level 'WARN' -Message ('Cluster {0}: no hosts found, alert state unknown' -f $Config.cluster)
        $rows += & $newAlert 'Unknown' 'Cluster' ([string]$Config.cluster) 'hosts' $null $null
    }

    $groups = @(
        @{ EntityType = 'VMHost'; Entities = $hosts; Thresholds = $alerts.host },
        @{ EntityType = 'VM'; Entities = $vms; Thresholds = $alerts.vm }
    )
    foreach ($group in $groups) {
        if ($group.Entities.Count -eq 0 -or -not $group.Thresholds) {
            continue
        }
        $metrics = @($group.Thresholds.PSObject.Properties | ForEach-Object { $_.Name })
        if ($metrics.Count -eq 0) {
            continue
        }
        $stats = @(Get-Stat -Entity $group.Entities -Stat $metrics -Realtime -MaxSamples $samples -Finish $Now)
        $summaries = @(Get-VAStatSummary -Sample $stats)
        $seen = @{}
        foreach ($row in $summaries) {
            $seen['{0}|{1}' -f $row.Entity, $row.MetricId] = $true
        }
        foreach ($entity in $group.Entities) {
            $entityName = [string]$entity.Name
            foreach ($metric in $metrics) {
                if (-not $seen.ContainsKey(('{0}|{1}' -f $entityName, $metric))) {
                    Write-VALog -Config $Config -Level 'WARN' -Message ('{0} {1}: no samples for {2}, state unknown' -f $group.EntityType, $entityName, $metric)
                    $rows += & $newAlert 'Unknown' $group.EntityType $entityName $metric $null $null
                }
            }
        }
        foreach ($row in $summaries) {
            $limit = $group.Thresholds.($row.MetricId)
            if (-not $limit) {
                continue
            }
            $value = & $round $row.Average
            if ($value -ge [double]$limit.crit) {
                $rows += & $newAlert 'Critical' $group.EntityType $row.Entity $row.MetricId $value ([double]$limit.crit)
            }
            elseif ($value -ge [double]$limit.warn) {
                $rows += & $newAlert 'Warning' $group.EntityType $row.Entity $row.MetricId $value ([double]$limit.warn)
            }
        }
    }

    $dsLimit = $alerts.datastoreFreePct
    if ($dsLimit -and $hosts.Count -gt 0) {
        $datastores = @(Get-Datastore -VMHost $hosts | Sort-Object -Property Name -Unique)
        foreach ($ds in $datastores) {
            if ([double]$ds.CapacityGB -le 0) {
                continue
            }
            $freePct = & $round (100 * [double]$ds.FreeSpaceGB / [double]$ds.CapacityGB)
            if ($freePct -le [double]$dsLimit.crit) {
                $rows += & $newAlert 'Critical' 'Datastore' ([string]$ds.Name) 'freeSpacePct' $freePct ([double]$dsLimit.crit)
            }
            elseif ($freePct -le [double]$dsLimit.warn) {
                $rows += & $newAlert 'Warning' 'Datastore' ([string]$ds.Name) 'freeSpacePct' $freePct ([double]$dsLimit.warn)
            }
        }
    }

    $critical = @($rows | Where-Object { $_.Severity -eq 'Critical' }).Count
    $unknown = @($rows | Where-Object { $_.Severity -eq 'Unknown' }).Count
    Write-VALog -Config $Config -Message ('Alerts: {0} critical, {1} warning, {2} unknown' -f $critical, ($rows.Count - $critical - $unknown), $unknown)
    foreach ($row in @($rows | Where-Object { $_.Severity -ne 'Unknown' })) {
        Write-VALog -Config $Config -Level 'WARN' -Message ('{0} {1} {2} {3}={4} (threshold {5})' -f $row.Severity, $row.EntityType, $row.Entity, $row.Metric, $row.Value, $row.Threshold)
    }
    $rows
}
