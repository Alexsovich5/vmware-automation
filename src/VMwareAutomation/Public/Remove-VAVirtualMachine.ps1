function Remove-VAVirtualMachine {
    <#
    .SYNOPSIS
        Powers a VM off and deletes it from disk, refusing VMs on the protected list.
    .DESCRIPTION
        Names in provisioning.protectedVMs are refused (case-insensitive) before any vCenter
        call. Otherwise the VM is looked up, stopped with Stop-VM when it is powered on, and
        removed with Remove-VM -DeletePermanently. With -WhatIf the lookup still runs and the
        plan is logged, but nothing is stopped or removed.
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
        $protected = @($Config.provisioning.protectedVMs)
    }
    foreach ($entry in $protected) {
        if ($entry -and ([string]$entry -eq $Name)) {
            $message = "VM '{0}' is protected and cannot be removed" -f $Name
            Write-VALog -Config $Config -Message $message -Level 'WARN'
            throw $message
        }
    }

    $vm = Get-VM -Name $Name -ErrorAction Stop
    if (-not $vm) {
        throw ("Could not find VirtualMachine with name '{0}'." -f $Name)
    }
    $vm = @($vm)[0]

    $plan = "{0} ({1})" -f $Name, $vm.PowerState
    if (-not $PSCmdlet.ShouldProcess($Name, 'Power off and permanently delete VM')) {
        Write-VALog -Config $Config -Message ("WhatIf: would remove {0}" -f $plan)
        return
    }

    if ($vm.PowerState -eq 'PoweredOn') {
        Write-VALog -Config $Config -Message ("Powering off {0}" -f $Name)
        $stopped = Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
        if ($stopped) {
            $vm = @($stopped)[0]
        }
    }

    Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
    Write-VALog -Config $Config -Message ("Removed {0} permanently" -f $Name)
}
