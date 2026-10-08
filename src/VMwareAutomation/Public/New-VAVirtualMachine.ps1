function New-VAVirtualMachine {
    <#
    .SYNOPSIS
        Validates a request, picks a host and datastore, clones the template, sizes the VM and
        powers it on.
    .DESCRIPTION
        Runs Test-VAVMRequest, Select-VAPlacementHost and Select-VADatastore, then
        New-VM -Name -Template -VMHost -Datastore, Set-VM -NumCpu -MemoryMB -Notes and
        Start-VM. With -WhatIf the checks and placement still run and are logged, but nothing
        is created. Returns the powered-on VM.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [string]$Template,

        [Parameter(Mandatory=$true)]
        [int]$NumCpu,

        [Parameter(Mandatory=$true)]
        [long]$MemoryMB,

        [string]$Datastore,

        [string]$Notes = ''
    )

    $null = Test-VAVMRequest -Config $Config -Name $Name -Template $Template -NumCpu $NumCpu -MemoryMB $MemoryMB
    $vmHost = Select-VAPlacementHost -Config $Config -MemoryMB $MemoryMB
    if ($Datastore) {
        $targetDatastore = Select-VADatastore -Config $Config -VMHost $vmHost -Template $Template -Datastore $Datastore
    }
    else {
        $targetDatastore = Select-VADatastore -Config $Config -VMHost $vmHost -Template $Template
    }

    $plan = "{0} from {1}: {2} vCPU, {3} MB on host {4}, datastore {5}" -f $Name, $Template, $NumCpu, $MemoryMB, $vmHost.Name, $targetDatastore.Name
    if (-not $PSCmdlet.ShouldProcess($Name, ("Create VM {0}" -f $plan))) {
        Write-VALog -Config $Config -Message ("WhatIf: would create {0}" -f $plan)
        return
    }

    Write-VALog -Config $Config -Message ("Creating {0}" -f $plan)
    $vm = New-VM -Name $Name -Template $Template -VMHost $vmHost -Datastore $targetDatastore -Confirm:$false -ErrorAction Stop
    $vm = Set-VM -VM $vm -NumCpu $NumCpu -MemoryMB $MemoryMB -Notes $Notes -Confirm:$false -ErrorAction Stop
    $vm = Start-VM -VM $vm -Confirm:$false -ErrorAction Stop
    Write-VALog -Config $Config -Message ("Created and powered on {0} on {1}" -f $Name, $vmHost.Name)
    $vm
}
