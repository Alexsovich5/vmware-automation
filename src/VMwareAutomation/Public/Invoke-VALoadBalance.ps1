function Invoke-VALoadBalance {
    <#
    .SYNOPSIS
        Carries out a load balancing plan with vMotion (Move-VM).
    .DESCRIPTION
        Uses -Plan when given, otherwise builds one with Get-VALoadBalancePlan. Each move runs
        Move-VM -VM -Destination -Confirm:$false in plan order and is logged; the first failed
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

    foreach ($move in $Plan) {
        $vmName = [string]$move.VM
        $destination = [string]$move.Destination
        if ($PSCmdlet.ShouldProcess($vmName, ("Migrate from {0} to {1}" -f $move.Source, $destination))) {
            try {
                $null = Move-VM -VM $vmName -Destination $destination -Confirm:$false -ErrorAction Stop
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
