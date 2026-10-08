$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Public/Get-VACapacityReport.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function New-TestCluster {
    param([string]$Name)
    New-Object psobject -Property @{ Name = $Name }
}

function New-TestHost {
    param([string]$Name, [int]$Cores, [int]$CpuTotalMhz, [int]$CpuUsageMhz = 0, [decimal]$TotalGB, [decimal]$UsedGB,
          [string]$State = 'Connected')
    New-Object psobject -Property @{
        Name = $Name; ConnectionState = $State; NumCpu = $Cores; CpuTotalMhz = $CpuTotalMhz
        CpuUsageMhz = $CpuUsageMhz; MemoryTotalGB = $TotalGB; MemoryUsageGB = $UsedGB
    }
}

function New-TestVM {
    param([string]$Name, [int]$NumCpu, [string]$PowerState = 'PoweredOn')
    New-Object psobject -Property @{ Name = $Name; NumCpu = $NumCpu; PowerState = $PowerState }
}

function New-TestDatastore {
    param([string]$Name, [decimal]$CapacityGB, [decimal]$FreeSpaceGB)
    New-Object psobject -Property @{ Name = $Name; CapacityGB = $CapacityGB; FreeSpaceGB = $FreeSpaceGB }
}

# The fixture's Lab-Cluster: 224 GB in three hosts, 122 GB allocated, 27 vCPUs powered on.
function Set-LabMocks {
    Mock Get-Cluster { New-TestCluster -Name 'Lab-Cluster' }
    Mock Get-VMHost {
        New-TestHost -Name 'esx01.lab.local' -Cores 12 -CpuTotalMhz 31200 -CpuUsageMhz 1370 -TotalGB 64 -UsedGB 10
        New-TestHost -Name 'esx02.lab.local' -Cores 12 -CpuTotalMhz 31200 -CpuUsageMhz 2660 -TotalGB 64 -UsedGB 28
        New-TestHost -Name 'esx03.lab.local' -Cores 16 -CpuTotalMhz 41600 -CpuUsageMhz 13270 -TotalGB 96 -UsedGB 84
    }
    Mock Get-VM {
        foreach ($n in @(1, 2, 1, 2, 2, 4, 4, 4, 2, 1, 2, 2)) { New-TestVM -Name ('vm{0}' -f $n) -NumCpu $n }
        New-TestVM -Name 'old-01' -NumCpu 2 -PowerState 'PoweredOff'
    }
    Mock Get-Datastore {
        New-TestDatastore -Name 'ds-ssd01' -CapacityGB 500 -FreeSpaceGB 180
        New-TestDatastore -Name 'ds-sata01' -CapacityGB 2000 -FreeSpaceGB 700
        New-TestDatastore -Name 'ds-sata02' -CapacityGB 1000 -FreeSpaceGB 150
    }
}

Describe 'Get-VACapacityReport' {

    Context 'the lab cluster' {
        $config = Get-TestConfig
        Set-LabMocks
        $report = @(Get-VACapacityReport -Config $config)

        It 'returns one row for the configured cluster' {
            $report.Count | Should Be 1
            $report[0].Cluster | Should Be 'Lab-Cluster'
            Assert-MockCalled Get-Cluster -ParameterFilter { @($Name) -contains 'Lab-Cluster' }
        }
        It 'totals CPU and memory over the hosts' {
            $report[0].Hosts | Should Be 3
            $report[0].CpuTotalMhz | Should Be 104000
            $report[0].CpuUsedMhz | Should Be 17300
            $report[0].MemoryTotalGB | Should Be 224
            $report[0].MemoryUsedGB | Should Be 122
        }
        It 'removes the largest host (96 GB) for the N+1 reserve' {
            $report[0].UsableMemoryGB | Should Be 128
        }
        It 'counts powered-on VMs, their vCPUs and the vCPU:pCore ratio' {
            $report[0].VMs | Should Be 12
            $report[0].vCPUs | Should Be 27
            $report[0].PCores | Should Be 40
            $report[0].VcpuPerCore | Should Be 0.68
        }
        It 'totals datastore free space' {
            $report[0].DatastoreFreeGB | Should Be 1030
        }
        It 'fits one more standard VM, limited by memory (6 GB left after N+1)' {
            $report[0].StandardVmsThatFit | Should Be 1
            $report[0].LimitedBy | Should Be 'Memory'
        }
        It 'reads the datastores mounted on the cluster hosts' {
            Assert-MockCalled Get-Datastore -ParameterFilter { @($VMHost).Count -eq 3 }
        }
    }

    Context 'vCPU ratio is the binding limit' {
        # N+1 removes the 8-core host, leaving 8 cores x 4 = 32 vCPUs; 28 are used, so 2 more
        # 2-vCPU VMs fit. Counting all 16 cores would allow 18.
        $config = Get-TestConfig
        Mock Get-Cluster { New-TestCluster -Name 'Lab-Cluster' }
        Mock Get-VMHost {
            New-TestHost -Name 'a' -Cores 4 -CpuTotalMhz 10000 -TotalGB 128 -UsedGB 5
            New-TestHost -Name 'b' -Cores 8 -CpuTotalMhz 20000 -TotalGB 256 -UsedGB 5
            New-TestHost -Name 'c' -Cores 4 -CpuTotalMhz 10000 -TotalGB 128 -UsedGB 0
        }
        Mock Get-VM { foreach ($i in 1..7) { New-TestVM -Name ('vm{0}' -f $i) -NumCpu 4 } }
        Mock Get-Datastore { New-TestDatastore -Name 'big' -CapacityGB 10000 -FreeSpaceGB 10000 }
        $report = @(Get-VACapacityReport -Config $config)

        It 'holds back the largest host''s memory and still reports all cores as PCores' {
            $report[0].UsableMemoryGB | Should Be 256
            $report[0].PCores | Should Be 16
        }
        It 'returns the vCPU limit as the minimum' {
            $report[0].StandardVmsThatFit | Should Be 2
            $report[0].LimitedBy | Should Be 'vCPU'
        }
    }

    Context 'storage is the binding limit' {
        # ds-a: 95 free - 10 reserve = 85 GB -> 2 x 40 GB; ds-b: 50 free is under its 100 GB reserve -> 0.
        $config = Get-TestConfig
        Mock Get-Cluster { New-TestCluster -Name 'Lab-Cluster' }
        Mock Get-VMHost {
            New-TestHost -Name 'a' -Cores 32 -CpuTotalMhz 80000 -TotalGB 512 -UsedGB 0
            New-TestHost -Name 'b' -Cores 32 -CpuTotalMhz 80000 -TotalGB 512 -UsedGB 0
        }
        Mock Get-VM {}
        Mock Get-Datastore {
            New-TestDatastore -Name 'ds-a' -CapacityGB 100 -FreeSpaceGB 95
            New-TestDatastore -Name 'ds-b' -CapacityGB 1000 -FreeSpaceGB 50
        }
        $report = @(Get-VACapacityReport -Config $config)

        It 'keeps the datastore reserve and counts whole standard disks per datastore' {
            $report[0].DatastoreFreeGB | Should Be 145
            $report[0].StandardVmsThatFit | Should Be 2
            $report[0].LimitedBy | Should Be 'Storage'
        }
    }

    Context 'hosts that are not connected' {
        $config = Get-TestConfig
        Mock Get-Cluster { New-TestCluster -Name 'Lab-Cluster' }
        Mock Get-VMHost {
            New-TestHost -Name 'a' -Cores 12 -CpuTotalMhz 31200 -TotalGB 64 -UsedGB 10
            New-TestHost -Name 'b' -Cores 12 -CpuTotalMhz 31200 -TotalGB 64 -UsedGB 10
            New-TestHost -Name 'm' -Cores 16 -CpuTotalMhz 41600 -TotalGB 96 -UsedGB 0 -State 'Maintenance'
        }
        Mock Get-VM {}
        Mock Get-Datastore { New-TestDatastore -Name 'big' -CapacityGB 10000 -FreeSpaceGB 10000 }
        $report = @(Get-VACapacityReport -Config $config)

        It 'leaves them out of the capacity' {
            $report[0].Hosts | Should Be 2
            $report[0].MemoryTotalGB | Should Be 128
            $report[0].UsableMemoryGB | Should Be 64
        }
    }

    Context 'a wildcard over a cluster with no hosts' {
        $config = Get-TestConfig
        Mock Get-Cluster {
            New-TestCluster -Name 'Empty-Cluster'
            New-TestCluster -Name 'Lab-Cluster'
        }
        Mock Get-VMHost {} -ParameterFilter { @($Location)[0].Name -eq 'Empty-Cluster' }
        Mock Get-VMHost {
            New-TestHost -Name 'a' -Cores 12 -CpuTotalMhz 31200 -TotalGB 64 -UsedGB 10
            New-TestHost -Name 'b' -Cores 12 -CpuTotalMhz 31200 -TotalGB 64 -UsedGB 10
        } -ParameterFilter { @($Location)[0].Name -eq 'Lab-Cluster' }
        Mock Get-VM {}
        Mock Get-Datastore { New-TestDatastore -Name 'big' -CapacityGB 10000 -FreeSpaceGB 10000 }

        $report = @(Get-VACapacityReport -Config $config -Cluster '*')
        $empty = @($report | Where-Object { $_.Cluster -eq 'Empty-Cluster' })

        It 'returns one row per cluster' {
            $report.Count | Should Be 2
            Assert-MockCalled Get-Cluster -ParameterFilter { @($Name) -contains '*' }
        }
        It 'gives zeros for the empty cluster' {
            $empty[0].Hosts | Should Be 0
            $empty[0].MemoryTotalGB | Should Be 0
            $empty[0].UsableMemoryGB | Should Be 0
            $empty[0].PCores | Should Be 0
            $empty[0].VcpuPerCore | Should Be 0
            $empty[0].DatastoreFreeGB | Should Be 0
            $empty[0].StandardVmsThatFit | Should Be 0
        }
    }

    Context 'a single host cannot cover its own N+1 reserve' {
        $config = Get-TestConfig
        Mock Get-Cluster { New-TestCluster -Name 'Lab-Cluster' }
        Mock Get-VMHost { New-TestHost -Name 'a' -Cores 12 -CpuTotalMhz 31200 -TotalGB 64 -UsedGB 10 }
        Mock Get-VM { New-TestVM -Name 'x' -NumCpu 2 }
        Mock Get-Datastore { New-TestDatastore -Name 'big' -CapacityGB 10000 -FreeSpaceGB 10000 }
        $report = @(Get-VACapacityReport -Config $config)

        It 'reports no usable memory and no room' {
            $report[0].UsableMemoryGB | Should Be 0
            $report[0].StandardVmsThatFit | Should Be 0
        }
    }
}
