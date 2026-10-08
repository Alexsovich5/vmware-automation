# FakePowerCLI: a JSON-backed stand-in for the PowerCLI 5.5 cmdlets used by VMwareAutomation.
# The inventory lives in the file named by $env:FAKEVI_STATE. Every cmdlet reads that file
# afresh, and only mutating cmdlets write it back, so separate processes share one state.

$script:NotConnectedMessage = 'You are not currently connected to any servers. Please connect first using a Connect cmdlet.'

# ---------------------------------------------------------------------------------------------
# State helpers (not exported)
# ---------------------------------------------------------------------------------------------

function Get-FakeViStatePath {
    if (-not $env:FAKEVI_STATE) {
        throw 'FakePowerCLI: FAKEVI_STATE is not set; point it at a copy of simulator/fixtures/lab-inventory.json.'
    }
    $env:FAKEVI_STATE
}

function Get-FakeViState {
    $path = Get-FakeViStatePath
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        throw ('FakePowerCLI: state file not found: {0}' -f $path)
    }
    (Get-Content -Path $path) -join "`n" | ConvertFrom-Json
}

function Save-FakeViState {
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$State
    )
    $State | ConvertTo-Json -Depth 20 | Set-Content -Path (Get-FakeViStatePath) -Encoding UTF8
}

function Assert-FakeViConnected {
    if (-not $global:DefaultVIServer -or -not $global:DefaultVIServer.IsConnected) {
        throw $script:NotConnectedMessage
    }
}

# Returns the inventory names for a mix of strings and objects with a Name property.
function Get-FakeViName {
    param([object[]]$InputObject)
    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $item }
        elseif ($item.PSObject.Properties['Name']) { [string]$item.Name }
        else { [string]$item }
    }
}

# Filters items by -Name patterns; writes PowerCLI's "Could not find" error for literal names
# that match nothing.
function Select-FakeViByName {
    param(
        [object[]]$Item,
        [string[]]$Name,
        [string]$TypeName
    )
    if (-not $Name) {
        return $Item
    }
    $selected = @()
    foreach ($pattern in $Name) {
        $found = @($Item | Where-Object { $_.name -like $pattern })
        if ($found.Count -eq 0 -and -not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($pattern)) {
            Write-Error -Message ("Could not find {0} with name '{1}'." -f $TypeName, $pattern) -Category ObjectNotFound -TargetObject $pattern
        }
        foreach ($f in $found) {
            if (-not ($selected -contains $f)) { $selected += $f }
        }
    }
    $selected
}

# Resolves -Location names (datacenter, cluster or host) to the set of host names they contain.
function Resolve-FakeViLocationHost {
    param(
        [psobject]$State,
        [object[]]$Location
    )
    $hostNames = @()
    foreach ($name in (Get-FakeViName $Location)) {
        $matched = $false
        foreach ($dc in @($State.datacenters | Where-Object { $_.name -like $name })) {
            $matched = $true
            $clusterNames = @($State.clusters | Where-Object { $_.datacenter -eq $dc.name } | ForEach-Object { $_.name })
            $hostNames += @($State.hosts | Where-Object { $clusterNames -contains $_.cluster } | ForEach-Object { $_.name })
        }
        foreach ($cluster in @($State.clusters | Where-Object { $_.name -like $name })) {
            $matched = $true
            $hostNames += @($State.hosts | Where-Object { $_.cluster -eq $cluster.name } | ForEach-Object { $_.name })
        }
        foreach ($h in @($State.hosts | Where-Object { $_.name -like $name })) {
            $matched = $true
            $hostNames += $h.name
        }
        if (-not $matched) {
            Write-Error -Message ("Could not find VIContainer with name '{0}'." -f $name) -Category ObjectNotFound -TargetObject $name
        }
    }
    @($hostNames | Select-Object -Unique)
}

# ---------------------------------------------------------------------------------------------
# Object builders: turn state records into PowerCLI-shaped objects
# ---------------------------------------------------------------------------------------------

function ConvertTo-FakeViCluster {
    param([psobject]$Record)
    $obj = New-Object psobject -Property @{
        Name       = $Record.name
        Id         = $Record.id
        HAEnabled  = [bool]$Record.haEnabled
        DrsEnabled = [bool]$Record.drsEnabled
    }
    $obj.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl')
    $obj
}

function ConvertTo-FakeViVMHost {
    param(
        [psobject]$State,
        [psobject]$Record
    )
    $running = @($State.vms | Where-Object { $_.host -eq $Record.name -and $_.powerState -eq 'PoweredOn' })
    $memUsedMB = 0
    $cpuUsedMhz = 0
    foreach ($vm in $running) {
        $memUsedMB += [int]$vm.memoryMB
        $cpuUsedMhz += [int]$vm.cpuUsageMhz
    }
    $parent = $null
    $clusterRecord = @($State.clusters | Where-Object { $_.name -eq $Record.cluster })
    if ($clusterRecord.Count -gt 0) {
        $parent = ConvertTo-FakeViCluster -Record $clusterRecord[0]
    }
    $obj = New-Object psobject -Property @{
        Name            = $Record.name
        Id              = $Record.id
        ConnectionState = $Record.connectionState
        PowerState      = 'PoweredOn'
        NumCpu          = [int]$Record.numCpu
        CpuTotalMhz     = [int]$Record.numCpu * [int]$Record.cpuMhzPerCore
        CpuUsageMhz     = $cpuUsedMhz
        MemoryTotalMB   = [decimal]$Record.memoryTotalMB
        MemoryUsageMB   = [decimal]$memUsedMB
        MemoryTotalGB   = [decimal]$Record.memoryTotalMB / 1024
        MemoryUsageGB   = [decimal]$memUsedMB / 1024
        Version         = $Record.version
        Build           = $Record.build
        Parent          = $parent
    }
    $obj.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.Inventory.VMHostImpl')
    $obj
}

function ConvertTo-FakeViVM {
    param(
        [psobject]$State,
        [psobject]$Record
    )
    $vmHost = $null
    $hostRecord = @($State.hosts | Where-Object { $_.name -eq $Record.host })
    if ($hostRecord.Count -gt 0) {
        $vmHost = ConvertTo-FakeViVMHost -State $State -Record $hostRecord[0]
    }
    $datastoreIds = @($State.datastores | Where-Object { $_.name -eq $Record.datastore } | ForEach-Object { $_.id })
    $obj = New-Object psobject -Property @{
        Name               = $Record.name
        Id                 = $Record.id
        PowerState         = $Record.powerState
        NumCpu             = [int]$Record.numCpu
        MemoryMB           = [decimal]$Record.memoryMB
        MemoryGB           = [decimal]$Record.memoryMB / 1024
        VMHost             = $vmHost
        VMHostId           = $(if ($hostRecord.Count -gt 0) { $hostRecord[0].id } else { $null })
        Notes              = $Record.notes
        GuestId            = $Record.guestId
        ProvisionedSpaceGB = [decimal]$Record.provisionedSpaceGB
        DatastoreIdList    = $datastoreIds
        Version            = 'v10'
    }
    $obj.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl')
    $obj
}

function ConvertTo-FakeViTemplate {
    param(
        [psobject]$State,
        [psobject]$Record
    )
    $obj = New-Object psobject -Property @{
        Name            = $Record.name
        Id              = $Record.id
        GuestId         = $Record.guestId
        DatastoreIdList = @($State.datastores | Where-Object { $_.name -eq $Record.datastore } | ForEach-Object { $_.id })
    }
    $obj.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.Inventory.TemplateImpl')
    $obj
}

function ConvertTo-FakeViDatastore {
    param([psobject]$Record)
    $obj = New-Object psobject -Property @{
        Name        = $Record.name
        Id          = $Record.id
        Type        = $Record.type
        State       = 'Available'
        Accessible  = $true
        CapacityGB  = [decimal]$Record.capacityGB
        FreeSpaceGB = [decimal]$Record.freeSpaceGB
        CapacityMB  = [decimal]$Record.capacityGB * 1024
        FreeSpaceMB = [decimal]$Record.freeSpaceGB * 1024
    }
    $obj.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl')
    $obj
}

# ---------------------------------------------------------------------------------------------
# Connection cmdlets
# ---------------------------------------------------------------------------------------------

function Connect-VIServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string[]]$Server,
        [int]$Port = 443,
        [string]$Protocol = 'https',
        [System.Management.Automation.PSCredential]$Credential,
        [string]$User,
        [string]$Password,
        [string]$Session,
        [switch]$NotDefault,
        [switch]$SaveCredentials,
        [switch]$AllLinked,
        [switch]$Force
    )

    $state = Get-FakeViState
    foreach ($name in $Server) {
        if ($name -ne $state.vCenter.server) {
            throw ("Could not resolve the requested VC server '{0}'." -f $name)
        }
        if ($Credential) {
            $User = $Credential.UserName
            $Password = $Credential.GetNetworkCredential().Password
        }
        if ($User -ne $state.vCenter.user -or $Password -cne $state.vCenter.password) {
            throw ("Cannot complete login due to an incorrect user name or password. (server '{0}')" -f $name)
        }

        $viServer = New-Object psobject -Property @{
            Name        = $state.vCenter.server
            Port        = $Port
            User        = $User
            IsConnected = $true
            Version     = $state.vCenter.version
            Build       = $state.vCenter.build
            ProductLine = 'vpx'
            ServiceUri  = ('{0}://{1}/sdk' -f $Protocol, $state.vCenter.server)
            SessionId   = [guid]::NewGuid().ToString()
        }
        $viServer.PSObject.TypeNames.Insert(0, 'VMware.VimAutomation.ViCore.Impl.V1.VIServerImpl')

        if (-not $NotDefault) {
            $global:DefaultVIServer = $viServer
            $global:DefaultVIServers = @($viServer)
        }
        $viServer
    }
}

function Disconnect-VIServer {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true)]
        [object[]]$Server,
        [switch]$Force
    )

    process {
        $targets = @()
        if ($Server) {
            $targets = @(Get-FakeViName $Server)
        }
        elseif ($global:DefaultVIServer) {
            $targets = @($global:DefaultVIServer.Name)
        }
        foreach ($name in $targets) {
            if (-not $PSCmdlet.ShouldProcess($name, 'Disconnect')) {
                continue
            }
            foreach ($open in @($global:DefaultVIServers)) {
                if ($open -and $open.Name -eq $name) {
                    $open.IsConnected = $false
                }
            }
            $global:DefaultVIServers = @($global:DefaultVIServers | Where-Object { $_ -and $_.Name -ne $name })
            if ($global:DefaultVIServer -and $global:DefaultVIServer.Name -eq $name) {
                $global:DefaultVIServer = $null
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Inventory cmdlets
# ---------------------------------------------------------------------------------------------

function Get-Cluster {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$Name,
        [object[]]$Location,
        [string[]]$Id,
        [object[]]$Server
    )

    Assert-FakeViConnected
    $state = Get-FakeViState
    $records = @($state.clusters)
    if ($Location) {
        $dcNames = @(Get-FakeViName $Location)
        $records = @($records | Where-Object { $dcNames -contains $_.datacenter })
    }
    if ($Id) {
        $records = @($records | Where-Object { $Id -contains $_.id })
    }
    foreach ($record in (Select-FakeViByName -Item $records -Name $Name -TypeName 'Cluster')) {
        ConvertTo-FakeViCluster -Record $record
    }
}

function Get-VMHost {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$Name,
        [object[]]$Location,
        [string]$State,
        [string[]]$Id,
        [object[]]$Server
    )

    Assert-FakeViConnected
    $viState = Get-FakeViState
    $records = @($viState.hosts)
    if ($Location) {
        $hostNames = @(Resolve-FakeViLocationHost -State $viState -Location $Location)
        $records = @($records | Where-Object { $hostNames -contains $_.name })
    }
    if ($State) {
        $records = @($records | Where-Object { $_.connectionState -eq $State })
    }
    if ($Id) {
        $records = @($records | Where-Object { $Id -contains $_.id })
    }
    foreach ($record in (Select-FakeViByName -Item $records -Name $Name -TypeName 'VMHost')) {
        ConvertTo-FakeViVMHost -State $viState -Record $record
    }
}

function Get-VM {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$Name,
        [object[]]$Location,
        [object[]]$Datastore,
        [string[]]$Id,
        [object[]]$Server
    )

    Assert-FakeViConnected
    $state = Get-FakeViState
    $records = @($state.vms)
    if ($Location) {
        $hostNames = @(Resolve-FakeViLocationHost -State $state -Location $Location)
        $records = @($records | Where-Object { $hostNames -contains $_.host })
    }
    if ($Datastore) {
        $dsNames = @(Get-FakeViName $Datastore)
        $records = @($records | Where-Object { $dsNames -contains $_.datastore })
    }
    if ($Id) {
        $records = @($records | Where-Object { $Id -contains $_.id })
    }
    foreach ($record in (Select-FakeViByName -Item $records -Name $Name -TypeName 'VirtualMachine')) {
        ConvertTo-FakeViVM -State $state -Record $record
    }
}

function Get-Template {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$Name,
        [object[]]$Location,
        [object[]]$Datastore,
        [string[]]$Id,
        [object[]]$Server
    )

    Assert-FakeViConnected
    $state = Get-FakeViState
    $records = @($state.templates)
    if ($Datastore) {
        $dsNames = @(Get-FakeViName $Datastore)
        $records = @($records | Where-Object { $dsNames -contains $_.datastore })
    }
    if ($Id) {
        $records = @($records | Where-Object { $Id -contains $_.id })
    }
    foreach ($record in (Select-FakeViByName -Item $records -Name $Name -TypeName 'Template')) {
        ConvertTo-FakeViTemplate -State $state -Record $record
    }
}

function Get-Datastore {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$Name,
        [object[]]$VMHost,
        [object[]]$VM,
        [object[]]$Location,
        [string[]]$Id,
        [switch]$Refresh,
        [object[]]$Server
    )

    Assert-FakeViConnected
    $state = Get-FakeViState
    $records = @($state.datastores)
    if ($VMHost) {
        $hostNames = @(Get-FakeViName $VMHost)
        $records = @($records | Where-Object {
            $mounted = @($_.hosts)
            @($hostNames | Where-Object { $mounted -contains $_ }).Count -gt 0
        })
    }
    if ($VM) {
        $vmNames = @(Get-FakeViName $VM)
        $dsNames = @($state.vms | Where-Object { $vmNames -contains $_.name } | ForEach-Object { $_.datastore })
        $records = @($records | Where-Object { $dsNames -contains $_.name })
    }
    if ($Location) {
        $hostNames = @(Resolve-FakeViLocationHost -State $state -Location $Location)
        $records = @($records | Where-Object {
            $mounted = @($_.hosts)
            @($hostNames | Where-Object { $mounted -contains $_ }).Count -gt 0
        })
    }
    if ($Id) {
        $records = @($records | Where-Object { $Id -contains $_.id })
    }
    foreach ($record in (Select-FakeViByName -Item $records -Name $Name -TypeName 'Datastore')) {
        ConvertTo-FakeViDatastore -Record $record
    }
}

Export-ModuleMember -Function @(
    'Connect-VIServer',
    'Disconnect-VIServer',
    'Get-Cluster',
    'Get-VMHost',
    'Get-VM',
    'Get-Template',
    'Get-Datastore'
)
