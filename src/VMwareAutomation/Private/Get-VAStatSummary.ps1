function Get-VAStatSummary {
    <#
    .SYNOPSIS
        Summarises Get-Stat samples into one row per entity and metric.
    .DESCRIPTION
        Groups the samples by entity name (the Entity object's Name, or the Entity itself when
        it is a string) and MetricId, and returns Entity, MetricId, Average, Maximum and Count
        for each group. Only aggregate samples (empty Instance) are used, so per-core or
        per-device instances do not skew the result.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Sample
    )

    $groups = @{}
    $order = @()
    foreach ($s in @($Sample)) {
        if ($null -eq $s) {
            continue
        }
        if ($s.PSObject.Properties['Instance'] -and $s.Instance) {
            continue
        }
        $entityName = [string]$s.Entity
        if ($s.Entity -and -not ($s.Entity -is [string]) -and $s.Entity.PSObject.Properties['Name']) {
            $entityName = [string]$s.Entity.Name
        }
        $key = '{0}|{1}' -f $entityName, $s.MetricId
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object psobject -Property @{
                Entity   = $entityName
                MetricId = [string]$s.MetricId
                Sum      = [double]0
                Maximum  = $null
                Count    = 0
            }
            $order += $key
        }
        $group = $groups[$key]
        $value = [double]$s.Value
        $group.Sum += $value
        $group.Count++
        if ($null -eq $group.Maximum -or $value -gt $group.Maximum) {
            $group.Maximum = $value
        }
    }

    foreach ($key in $order) {
        $group = $groups[$key]
        New-Object psobject -Property ([ordered]@{
            Entity   = $group.Entity
            MetricId = $group.MetricId
            Average  = $group.Sum / $group.Count
            Maximum  = $group.Maximum
            Count    = $group.Count
        })
    }
}
