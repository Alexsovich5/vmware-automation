# Empty functions with PowerCLI 5.5 parameter names, so Pester 2 can Mock them in unit tests.
# Each stub is defined only when the command does not already exist in the session.
# Get-PSSnapin and Add-PSSnapin are stubbed too, because pwsh has no snap-in support.
# Pester 2.0.4 has an internal Get-Template (used by New-Fixture) that is visible from test
# scope, so a command defined in a file of the Pester module itself does not count as existing.

function Test-PowerCLIStubNeeded {
    param([string]$Name)
    $existing = @(Get-Command -Name $Name -ErrorAction SilentlyContinue | Where-Object {
        $pesterInternal = $_.ModuleName -eq 'Pester' -and $_.Module -and $_.ScriptBlock -and
            $_.ScriptBlock.File -and $_.ScriptBlock.File.StartsWith($_.Module.ModuleBase)
        -not $pesterInternal
    })
    $existing.Count -eq 0
}

if (Test-PowerCLIStubNeeded -Name 'Get-PSSnapin') {
    function Get-PSSnapin {
        [CmdletBinding()]
        param([Parameter(Position=0)][string[]]$Name, [switch]$Registered)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Add-PSSnapin') {
    function Add-PSSnapin {
        [CmdletBinding()]
        param([Parameter(Position=0, Mandatory=$true)][string[]]$Name, [switch]$PassThru)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Connect-VIServer') {
    function Connect-VIServer {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Server, [int]$Port, [string]$Protocol,
            [System.Management.Automation.PSCredential]$Credential, [string]$User, [string]$Password,
            [string]$Session, [switch]$NotDefault, [switch]$SaveCredentials, [switch]$AllLinked, [switch]$Force
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Disconnect-VIServer') {
    function Disconnect-VIServer {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$Server, [switch]$Force)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-Cluster') {
    function Get-Cluster {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Name, [object[]]$Location, [object[]]$VM, [object[]]$VMHost,
            [switch]$NoRecursion, [string[]]$Id, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-VMHost') {
    function Get-VMHost {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Name, [object[]]$Location, [object[]]$Datastore, [object[]]$VM,
            [object[]]$ResourcePool, [string]$State, [switch]$Standalone, [switch]$NoRecursion,
            [string[]]$Id, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-VM') {
    function Get-VM {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Name, [object[]]$Location, [object[]]$Datastore,
            [switch]$NoRecursion, [string[]]$Id, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-Template') {
    function Get-Template {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Name, [object[]]$Location, [object[]]$Datastore,
            [switch]$NoRecursion, [string[]]$Id, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-Datastore') {
    function Get-Datastore {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)][string[]]$Name, [object[]]$Location, [object[]]$VMHost, [object[]]$VM,
            [object[]]$Entity, [switch]$Refresh, [string[]]$Id, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'New-VM') {
    function New-VM {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param(
            [Parameter(Position=0)][string]$Name, [object]$VMHost, [object]$ResourcePool, [object]$Location,
            [object]$Datastore, [object]$Template, [object]$VM, [int]$NumCpu, [long]$MemoryMB, [decimal]$MemoryGB,
            [decimal[]]$DiskGB, [long[]]$DiskMB, [string]$DiskStorageFormat, [object]$OSCustomizationSpec,
            [string]$GuestId, [string]$Version, [string[]]$NetworkName, [string]$Notes,
            [switch]$RunAsync, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Set-VM') {
    function Set-VM {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
        param(
            [Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [string]$Name, [int]$NumCpu,
            [long]$MemoryMB, [decimal]$MemoryGB, [string]$Notes, [string]$GuestId, [string]$Version,
            [object]$OSCustomizationSpec, [object]$Snapshot, [switch]$ToTemplate, [switch]$RunAsync, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Start-VM') {
    function Start-VM {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [switch]$RunAsync, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Stop-VM') {
    function Stop-VM {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [switch]$Kill, [switch]$RunAsync, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Remove-VM') {
    function Remove-VM {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [switch]$DeletePermanently, [switch]$RunAsync, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Move-VM') {
    function Move-VM {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param(
            [Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [object]$Destination, [object]$Datastore,
            [string]$DiskStorageFormat, [switch]$RunAsync, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-Snapshot') {
    function Get-Snapshot {
        [CmdletBinding()]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [string[]]$Name, [string[]]$Id, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'New-Snapshot') {
    function New-Snapshot {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param(
            [Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VM, [string]$Name, [string]$Description,
            [switch]$Memory, [switch]$Quiesce, [switch]$RunAsync, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Remove-Snapshot') {
    function Remove-Snapshot {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$Snapshot, [switch]$RemoveChildren, [switch]$RunAsync)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-Stat') {
    function Get-Stat {
        [CmdletBinding()]
        param(
            [Parameter(Position=0, ValueFromPipeline=$true)][object[]]$Entity, [string[]]$Stat,
            [datetime]$Start, [datetime]$Finish, [int]$MaxSamples, [int[]]$IntervalMins, [int[]]$IntervalSecs,
            [string[]]$Instance, [switch]$Realtime, [switch]$Common, [switch]$Cpu, [switch]$Memory,
            [switch]$Disk, [switch]$Network, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-AdvancedSetting') {
    function Get-AdvancedSetting {
        [CmdletBinding()]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$Entity, [string[]]$Name, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Set-AdvancedSetting') {
    function Set-AdvancedSetting {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$AdvancedSetting, [object]$Value, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'New-AdvancedSetting') {
    function New-AdvancedSetting {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
        param(
            [Parameter(Position=0, ValueFromPipeline=$true)][object[]]$Entity, [string]$Name, [object]$Value,
            [string]$Type, [switch]$Force, [object[]]$Server
        )
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-VMHostService') {
    function Get-VMHostService {
        [CmdletBinding()]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VMHost, [switch]$Refresh, [object[]]$Server)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Stop-VMHostService') {
    function Stop-VMHostService {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$HostService)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Set-VMHostService') {
    function Set-VMHostService {
        [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$HostService, [string]$Policy)
    }
}

if (Test-PowerCLIStubNeeded -Name 'Get-VMHostNtpServer') {
    function Get-VMHostNtpServer {
        [CmdletBinding()]
        param([Parameter(Position=0, ValueFromPipeline=$true)][object[]]$VMHost, [object[]]$Server)
    }
}
