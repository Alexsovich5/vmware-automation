function Invoke-VALoadBalance {
    <#
    .SYNOPSIS
        Carries out a load balancing plan with vMotion (Move-VM).
    .DESCRIPTION
        Uses -Plan when given, otherwise builds one with Get-VALoadBalancePlan. A move whose VM
        is in loadBalance.excludeVMs (case-insensitive) is refused. Before each migration the VM
        and the destination host are resolved with Resolve-VAExactEntity (no wildcards, exactly
        one object per name) and the exclusion list is checked again on the resolved VM name;
        Move-VM -VM -Destination -Confirm:$false then receives those objects, never a name it
        could expand. Moves run in plan order and are logged; the first refused or failed
        migration stops the run with that error. Returns rows (Order, VM, Source, Destination,
        SpreadBefore, SpreadAfter, Action) with Action Moved, or WouldMove under -WhatIf, when
        nothing is migrated.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [object[]]$Plan
    )

    if (-not $PSBoundParameters.ContainsKey('Plan')) {
        $Plan = @(Get-VALoadBalancePlan -Config $Config)
    }
    $Plan = @($Plan | Where-Object { $null -ne $_ })
    if ($Plan.Count -eq 0) {
        Write-VALog -Config $Config -Message ('Load balance: {0} is balanced, no migrations needed' -f $Config.cluster)
        return
    }

    $excluded = @()
    if ($Config.loadBalance -and $Config.loadBalance.PSObject.Properties['excludeVMs']) {
        $excluded = @($Config.loadBalance.excludeVMs | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    $assertNotExcluded = {
        param([string]$VMName)
        if ($excluded -contains $VMName) {
            $message = "VM '{0}' is excluded from load balancing (loadBalance.excludeVMs)" -f $VMName
            Write-VALog -Config $Config -Message $message -Level 'ERROR' -Source 'Invoke-VALoadBalance'
            throw $message
        }
    }

    foreach ($move in $Plan) {
        $vmName = [string]$move.VM
        $destination = [string]$move.Destination
        & $assertNotExcluded $vmName
        if ($PSCmdlet.ShouldProcess($vmName, ("Migrate from {0} to {1}" -f $move.Source, $destination))) {
            try {
                $vm = Resolve-VAExactEntity -EntityType VM -Name $vmName
                $vmHost = Resolve-VAExactEntity -EntityType VMHost -Name $destination
                & $assertNotExcluded ([string]$vm.Name)
                $null = Move-VM -VM $vm -Destination $vmHost -Confirm:$false -ErrorAction Stop
            }
            catch {
                Write-VALog -Config $Config -Message ('Load balance: moving {0} to {1} failed: {2}' -f $vmName, $destination, $_.Exception.Message) -Level 'ERROR'
                throw
            }
            Write-VALog -Config $Config -Message ('Load balance: moved {0} from {1} to {2}' -f $vmName, $move.Source, $destination)
            $action = 'Moved'
        }
        else {
            Write-VALog -Config $Config -Message ('WhatIf: would move {0} from {1} to {2}' -f $vmName, $move.Source, $destination)
            $action = 'WouldMove'
        }
        New-Object psobject -Property ([ordered]@{
            Order        = $move.Order
            VM           = $vmName
            Source       = [string]$move.Source
            Destination  = $destination
            SpreadBefore = $move.SpreadBefore
            SpreadAfter  = $move.SpreadAfter
            Action       = $action
        })
    }
}
