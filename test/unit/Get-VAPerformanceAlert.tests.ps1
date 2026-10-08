$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Get-VAStatSummary.ps1')
. (Join-Path $src 'Public/Get-VAPerformanceAlert.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'
$fixedNow = [datetime]'2014-03-15T02:00:00'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function New-TestHost {
    param([string]$Name, [string]$ConnectionState = 'Connected')
    New-Object psobject -Property @{ Name = $Name; ConnectionState = $ConnectionState }
}

function New-TestVM {
    param([string]$Name, [string]$PowerState = 'PoweredOn')
    New-Object psobject -Property @{ Name = $Name; PowerState = $PowerState }
}

function New-TestDatastore {
    param([string]$Name, [decimal]$CapacityGB, [decimal]$FreeSpaceGB)
    New-Object psobject -Property @{ Name = $Name; CapacityGB = $CapacityGB; FreeSpaceGB = $FreeSpaceGB }
}

# Returns samples only for entities in $Requested, as Get-Stat does for its -Entity list.
function New-TestSamples {
    param([string]$Entity, [string]$MetricId, [double[]]$Values, [object[]]$Requested)
    if (@($Requested | ForEach-Object { $_.Name }) -notcontains $Entity) {
        return
    }
    $owner = New-Object psobject -Property @{ Name = $Entity }
    foreach ($v in $Values) {
        New-Object psobject -Property @{ Entity = $owner; MetricId = $MetricId; Value = $v; Instance = '' }
    }
}

function Get-Alert {
    param([object[]]$Rows, [string]$Entity, [string]$Metric)
    @($Rows | Where-Object { $_.Entity -eq $Entity -and $_.Metric -eq $Metric })
}

Describe 'Get-VAPerformanceAlert' {

    Context 'host and VM threshold boundaries' {
        $config = Get-TestConfig
        Mock Get-VMHost {
            New-TestHost 'h-warn'
            New-TestHost 'h-crit'
            New-TestHost 'h-below'
            New-TestHost 'h-over'
        }
        Mock Get-VM {
            New-TestVM 'vm-warn'
            New-TestVM 'vm-ok'
            New-TestVM 'vm-off' -PowerState 'PoweredOff'
        }
        Mock Get-Datastore { }
        Mock Get-Stat {
            if (@($Entity | ForEach-Object { $_.Name }) -contains 'h-warn') {
                # host cpu warn 75 crit 90; mem warn 80 crit 95
                New-TestSamples 'h-warn' 'cpu.usage.average' @(70, 80, 75) $Entity
                New-TestSamples 'h-warn' 'mem.usage.average' @(10) $Entity
                New-TestSamples 'h-crit' 'cpu.usage.average' @(20) $Entity
                New-TestSamples 'h-crit' 'mem.usage.average' @(94, 96) $Entity
                New-TestSamples 'h-below' 'cpu.usage.average' @(74.99) $Entity
                New-TestSamples 'h-below' 'mem.usage.average' @(79.9) $Entity
                New-TestSamples 'h-over' 'cpu.usage.average' @(99) $Entity
                New-TestSamples 'h-over' 'mem.usage.average' @(20) $Entity
            }
            else {
                # vm cpu/mem warn 85 crit 95
                New-TestSamples 'vm-warn' 'cpu.usage.average' @(85) $Entity
                New-TestSamples 'vm-warn' 'mem.usage.average' @(50) $Entity
                New-TestSamples 'vm-ok' 'cpu.usage.average' @(84) $Entity
                New-TestSamples 'vm-ok' 'mem.usage.average' @(84.9) $Entity
                New-TestSamples 'vm-off' 'cpu.usage.average' @(99) $Entity
            }
        }

        $rows = @(Get-VAPerformanceAlert -Config $config -Now $fixedNow)

        It 'reports a value equal to warn as a Warning with the warn threshold' {
            $a = @(Get-Alert $rows 'h-warn' 'cpu.usage.average')
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Warning'
            $a[0].EntityType | Should Be 'VMHost'
            $a[0].Value | Should Be 75
            $a[0].Threshold | Should Be 75
            $a[0].Timestamp | Should Be $fixedNow
        }
        It 'reports a value equal to crit as Critical with the crit threshold' {
            $a = @(Get-Alert $rows 'h-crit' 'mem.usage.average')
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Critical'
            $a[0].Value | Should Be 95
            $a[0].Threshold | Should Be 95
        }
        It 'gives no alert just below warn' {
            @($rows | Where-Object { $_.Entity -eq 'h-below' }).Count | Should Be 0
            @($rows | Where-Object { $_.Entity -eq 'vm-ok' }).Count | Should Be 0
        }
        It 'gives an entity only its highest severity' {
            $a = @(Get-Alert $rows 'h-over' 'cpu.usage.average')
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Critical'
            $a[0].Threshold | Should Be 90
        }
        It 'uses the VM thresholds for VMs' {
            $a = @(Get-Alert $rows 'vm-warn' 'cpu.usage.average')
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Warning'
            $a[0].EntityType | Should Be 'VM'
            $a[0].Threshold | Should Be 85
        }
        It 'ignores powered-off VMs' {
            @($rows | Where-Object { $_.Entity -eq 'vm-off' }).Count | Should Be 0
        }
        It 'returns exactly the expected alerts' {
            $rows.Count | Should Be 4
        }
        It 'asks for the last alerts.samples realtime samples up to -Now' {
            Assert-MockCalled Get-Stat -Times 2 -Exactly
            Assert-MockCalled Get-Stat -Times 2 -Exactly -ParameterFilter {
                $Realtime -and $MaxSamples -eq 6 -and $Finish -eq $fixedNow
            }
        }
    }

    Context 'hosts and VMs that return no samples' {
        $config = Get-TestConfig
        Mock Get-VMHost {
            New-TestHost 'h-ok'
            New-TestHost 'h-silent'
            New-TestHost 'h-down' -ConnectionState 'NotResponding'
        }
        Mock Get-VM {
            New-TestVM 'vm-ok'
            New-TestVM 'vm-new'
            New-TestVM 'vm-off' -PowerState 'PoweredOff'
        }
        Mock Get-Datastore { }
        Mock Get-Stat {
            New-TestSamples 'h-ok' 'cpu.usage.average' @(10) $Entity
            New-TestSamples 'h-ok' 'mem.usage.average' @(10) $Entity
            New-TestSamples 'h-silent' 'cpu.usage.average' @(10) $Entity
            New-TestSamples 'vm-ok' 'cpu.usage.average' @(10) $Entity
            New-TestSamples 'vm-ok' 'mem.usage.average' @(10) $Entity
        }

        $rows = @(Get-VAPerformanceAlert -Config $config -Now $fixedNow)
        $unknown = @($rows | Where-Object { $_.Severity -eq 'Unknown' })

        It 'reports each missing host metric as Unknown instead of healthy' {
            @(Get-Alert $unknown 'h-silent' 'mem.usage.average').Count | Should Be 1
            @(Get-Alert $unknown 'h-silent' 'cpu.usage.average').Count | Should Be 0
            @(Get-Alert $unknown 'h-down' 'cpu.usage.average').Count | Should Be 1
            @(Get-Alert $unknown 'h-down' 'mem.usage.average').Count | Should Be 1
        }
        It 'reports a powered-on VM without samples as Unknown' {
            @(Get-Alert $unknown 'vm-new' 'cpu.usage.average').Count | Should Be 1
            @(Get-Alert $unknown 'vm-new' 'mem.usage.average').Count | Should Be 1
        }
        It 'leaves entities with samples and powered-off VMs out' {
            @($rows | Where-Object { $_.Entity -eq 'h-ok' -or $_.Entity -eq 'vm-ok' -or $_.Entity -eq 'vm-off' }).Count | Should Be 0
        }
        It 'gives Unknown rows the entity type, no value and no threshold' {
            $a = @(Get-Alert $unknown 'h-down' 'cpu.usage.average')[0]
            $a.EntityType | Should Be 'VMHost'
            $a.Value | Should BeNullOrEmpty
            $a.Threshold | Should BeNullOrEmpty
            $a.Timestamp | Should Be $fixedNow
            @(Get-Alert $unknown 'vm-new' 'cpu.usage.average')[0].EntityType | Should Be 'VM'
        }
        It 'returns exactly the five Unknown rows' {
            $rows.Count | Should Be 5
            $unknown.Count | Should Be 5
        }
        It 'logs the missing samples as a warning' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'WARN.*h-down.*no samples'
        }
    }

    Context 'a cluster with no hosts' {
        $config = Get-TestConfig
        Mock Get-VMHost { }
        Mock Get-VM { }
        Mock Get-Datastore { }
        Mock Get-Stat { }

        $rows = @(Get-VAPerformanceAlert -Config $config -Now $fixedNow)

        It 'reports the cluster as Unknown instead of returning no alerts' {
            $rows.Count | Should Be 1
            $rows[0].Severity | Should Be 'Unknown'
            $rows[0].EntityType | Should Be 'Cluster'
            $rows[0].Entity | Should Be 'Lab-Cluster'
        }
    }

    Context 'datastore free space' {
        $config = Get-TestConfig
        Mock Get-VMHost { New-TestHost 'h1' }
        Mock Get-VM { }
        Mock Get-Stat {
            New-TestSamples 'h1' 'cpu.usage.average' @(10) $Entity
            New-TestSamples 'h1' 'mem.usage.average' @(10) $Entity
        }
        Mock Get-Datastore {
            New-TestDatastore 'ds-warn' 1000 150
            New-TestDatastore 'ds-crit' 1000 50
            New-TestDatastore 'ds-ok' 1000 201
            New-TestDatastore 'ds-edge' 500 100
        }

        $rows = @(Get-VAPerformanceAlert -Config $config -Now $fixedNow)

        It 'reports 15% free as a Warning' {
            $a = @($rows | Where-Object { $_.Entity -eq 'ds-warn' })
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Warning'
            $a[0].EntityType | Should Be 'Datastore'
            $a[0].Value | Should Be 15
            $a[0].Threshold | Should Be 20
        }
        It 'reports 5% free as Critical' {
            $a = @($rows | Where-Object { $_.Entity -eq 'ds-crit' })
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Critical'
            $a[0].Threshold | Should Be 10
        }
        It 'reports exactly 20% free as a Warning and above it nothing' {
            @($rows | Where-Object { $_.Entity -eq 'ds-edge' })[0].Severity | Should Be 'Warning'
            @($rows | Where-Object { $_.Entity -eq 'ds-ok' }).Count | Should Be 0
        }
    }

    Context 'without -Now' {
        $config = Get-TestConfig
        $saved = $env:FAKEVI_NOW
        $env:FAKEVI_NOW = '2014-04-01T08:30:00'
        Mock Get-VMHost { New-TestHost 'h1' }
        Mock Get-VM { }
        Mock Get-Datastore { }
        Mock Get-Stat {
            New-TestSamples 'h1' 'cpu.usage.average' @(10) $Entity
            New-TestSamples 'h1' 'mem.usage.average' @(99) $Entity
        }

        $rows = @(Get-VAPerformanceAlert -Config $config)
        $env:FAKEVI_NOW = $saved

        It 'uses the shared clock for the window and the timestamp' {
            Assert-MockCalled Get-Stat -Times 1 -Exactly -ParameterFilter { $Finish -eq [datetime]'2014-04-01T08:30:00' }
            $rows[0].Timestamp | Should Be ([datetime]'2014-04-01T08:30:00')
        }
    }
}
