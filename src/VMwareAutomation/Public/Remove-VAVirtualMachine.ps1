function Remove-VAVirtualMachine {
    <#
    .SYNOPSIS
        Powers a VM off and deletes it from disk, refusing VMs on the protected list.
    .DESCRIPTION
        Names in provisioning.protectedVMs are refused (case-insensitive) before any vCenter
        call. The VM is then resolved with Resolve-VAExactEntity: wildcard characters are
        rejected and exactly one VM must carry the name, so a pattern or a duplicate name
        never reaches a destructive call. The protected list is checked again on the resolved
        VM's own name, then the VM is stopped with Stop-VM when it is powered on and removed
        with Remove-VM -DeletePermanently; both calls receive the resolved object, not the
        name. With -WhatIf the lookup still runs and the plan is logged, but nothing is
        stopped or removed.
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $protected = @()
    if ($Config.provisioning -and $Config.provisioning.PSObject.Properties['protectedVMs']) {
        $protected = @($Config.provisioning.protectedVMs | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    $assertNotProtected = {
        param([string]$VMName)
        if ($protected -contains $VMName) {
            $message = "VM '{0}' is protected and cannot be removed" -f $VMName
            Write-VALog -Config $Config -Message $message -Level 'WARN' -Source 'Remove-VAVirtualMachine'
            throw $message
        }
    }

    & $assertNotProtected $Name
    $vm = Resolve-VAExactEntity -EntityType VM -Name $Name
    $vmName = [string]$vm.Name
    & $assertNotProtected $vmName

    $plan = "{0} ({1})" -f $vmName, $vm.PowerState
    if (-not $PSCmdlet.ShouldProcess($vmName, 'Power off and permanently delete VM')) {
        Write-VALog -Config $Config -Message ("WhatIf: would remove {0}" -f $plan)
        return
    }

    if ("$($vm.PowerState)" -eq 'PoweredOn') {
        Write-VALog -Config $Config -Message ("Powering off {0}" -f $vmName)
        $stopped = @(Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop | Where-Object { $_ })
        if ($stopped.Count -eq 1 -and [string]$stopped[0].Name -eq $vmName) {
            $vm = $stopped[0]
        }
    }

    & $assertNotProtected ([string]$vm.Name)
    Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
    Write-VALog -Config $Config -Message ("Removed {0} permanently" -f $vmName)
}
