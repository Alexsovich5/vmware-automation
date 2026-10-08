function Get-VASnapshotAge {
    <#
    .SYNOPSIS
        Lists every snapshot in the config's cluster with its age, for reporting only.
    .DESCRIPTION
        Reads snapshots of all VMs in the cluster with one Get-Snapshot call and returns rows
        (VM, Snapshot, Created, AgeDays, IsAuto, Stale), oldest first. AgeDays is the number of
        whole days between Created and -Now (default Get-VANow). IsAuto is true for names that
        start with "<snapshots.prefix>-". Stale is true when AgeDays is greater than
        snapshots.staleDays, for auto snapshots too: an auto snapshot that old means rotation
        is not running for it. Nothing is created or removed.
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
    $autoPattern = '{0}-*' -f $Config.snapshots.prefix
    $staleDays = [int]$Config.snapshots.staleDays

    $vms = @(Get-VM -Location $Config.cluster)
    if ($vms.Count -eq 0) {
        return
    }

    $rows = foreach ($snapshot in @(Get-Snapshot -VM $vms)) {
        $created = [datetime]$snapshot.Created
        $ageDays = [int][math]::Floor(($Now - $created).TotalDays)
        New-Object psobject -Property ([ordered]@{
            VM       = [string]$snapshot.VM.Name
            Snapshot = [string]$snapshot.Name
            Created  = $created
            AgeDays  = $ageDays
            IsAuto   = ([string]$snapshot.Name -like $autoPattern)
            Stale    = ($ageDays -gt $staleDays)
        })
    }
    @($rows) | Sort-Object Created
}
