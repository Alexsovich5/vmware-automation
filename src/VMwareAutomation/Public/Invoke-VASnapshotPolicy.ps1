function Invoke-VASnapshotPolicy {
    <#
    .SYNOPSIS
        Applies the snapshot policies from config: snapshots matching VMs and prunes old auto snapshots.
    .DESCRIPTION
        For each policy in snapshots.policies (or only -PolicyName), every VM in the config's
        cluster whose name matches vmNamePattern gets a new snapshot named
        "<prefix>-<policy>-yyyyMMdd-HHmm" from -Now (default Get-VANow), taken with the policy's
        memory and quiesce options. The VM's existing "<prefix>-<policy>-*" snapshots are then
        pruned: those older than retentionDays go first, then the oldest of the rest until no
        more than maxSnapshots remain, counting the new one. Snapshots without the prefix are
        manual: they are never removed, and those older than snapshots.staleDays are reported.
        Returns rows (Policy, VM, Snapshot, Action) with Action Created, Removed or Stale; with
        -WhatIf nothing changes and the rows say WouldCreate or WouldRemove instead.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [string]$PolicyName,

        [datetime]$Now
    )

    if (-not $PSBoundParameters.ContainsKey('Now')) {
        $Now = Get-VANow
    }
    $prefix = [string]$Config.snapshots.prefix
    $staleDays = [int]$Config.snapshots.staleDays

    $policies = @($Config.snapshots.policies)
    if ($PolicyName) {
        $policies = @($policies | Where-Object { $_.name -eq $PolicyName })
        if ($policies.Count -eq 0) {
            $message = "Snapshot policy '{0}' is not defined in the config" -f $PolicyName
            Write-VALog -Config $Config -Message $message -Level 'ERROR'
            throw $message
        }
    }

    $newRow = {
        param($Policy, $VM, $Snapshot, $Action)
        New-Object psobject -Property ([ordered]@{
            Policy   = $Policy
            VM       = $VM
            Snapshot = $Snapshot
            Action   = $Action
        })
    }

    $clusterVMs = @(Get-VM -Location $Config.cluster)
    foreach ($policy in $policies) {
        $name = [string]$policy.name
        $vms = @($clusterVMs | Where-Object { [string]$_.Name -like [string]$policy.vmNamePattern })
        if ($vms.Count -eq 0) {
            Write-VALog -Config $Config -Message ("Policy {0}: no VMs match {1}" -f $name, $policy.vmNamePattern)
            continue
        }

        $autoPattern = '{0}-{1}-*' -f $prefix, $name
        $snapshotName = '{0}-{1}-{2}' -f $prefix, $name, $Now.ToString('yyyyMMdd-HHmm')
        $retentionDays = [int]$policy.retentionDays
        $maxSnapshots = [int]$policy.maxSnapshots
        $existing = @(Get-Snapshot -VM $vms)

        foreach ($vm in $vms) {
            $vmName = [string]$vm.Name
            $snapshots = @($existing | Where-Object { [string]$_.VM.Name -eq $vmName })
            $auto = @($snapshots | Where-Object { [string]$_.Name -like $autoPattern -and [string]$_.Name -ne $snapshotName } |
                Sort-Object { [datetime]$_.Created } -Descending)

            # 1. Take the new snapshot.
            if ($PSCmdlet.ShouldProcess($vmName, ("Create snapshot '{0}'" -f $snapshotName))) {
                $null = New-Snapshot -VM $vm -Name $snapshotName -Description ("Created by snapshot policy '{0}'" -f $name) `
                    -Memory:([bool]$policy.memory) -Quiesce:([bool]$policy.quiesce) -Confirm:$false -ErrorAction Stop
                Write-VALog -Config $Config -Message ("Policy {0}: created {1} on {2}" -f $name, $snapshotName, $vmName)
                & $newRow $name $vmName $snapshotName 'Created'
            }
            else {
                Write-VALog -Config $Config -Message ("WhatIf: policy {0} would create {1} on {2}" -f $name, $snapshotName, $vmName)
                & $newRow $name $vmName $snapshotName 'WouldCreate'
            }

            # 2. Prune auto snapshots by age, then by count (the new snapshot takes one slot).
            $keepSlots = [math]::Max(0, $maxSnapshots - 1)
            $kept = 0
            $prune = @()
            foreach ($snapshot in $auto) {
                $tooOld = ($Now - [datetime]$snapshot.Created).TotalDays -gt $retentionDays
                if ($tooOld -or $kept -ge $keepSlots) {
                    $prune += $snapshot
                }
                else {
                    $kept++
                }
            }
            foreach ($snapshot in @($prune | Sort-Object { [datetime]$_.Created })) {
                $label = [string]$snapshot.Name
                if ($PSCmdlet.ShouldProcess($vmName, ("Remove snapshot '{0}'" -f $label))) {
                    Remove-Snapshot -Snapshot $snapshot -Confirm:$false -ErrorAction Stop
                    Write-VALog -Config $Config -Message ("Policy {0}: removed {1} from {2}" -f $name, $label, $vmName)
                    & $newRow $name $vmName $label 'Removed'
                }
                else {
                    Write-VALog -Config $Config -Message ("WhatIf: policy {0} would remove {1} from {2}" -f $name, $label, $vmName)
                    & $newRow $name $vmName $label 'WouldRemove'
                }
            }

            # 3. Report manual snapshots that have been left behind.
            foreach ($snapshot in @($snapshots | Where-Object { [string]$_.Name -notlike ('{0}-*' -f $prefix) } | Sort-Object { [datetime]$_.Created })) {
                $ageDays = ($Now - [datetime]$snapshot.Created).TotalDays
                if ($ageDays -gt $staleDays) {
                    Write-VALog -Config $Config -Message ("Policy {0}: manual snapshot {1} on {2} is {3} days old" -f $name, $snapshot.Name, $vmName, [int][math]::Floor($ageDays)) -Level 'WARN'
                    & $newRow $name $vmName ([string]$snapshot.Name) 'Stale'
                }
            }
        }
    }
}
