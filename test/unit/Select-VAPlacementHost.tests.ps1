$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Read-VAConfig.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Select-VAPlacementHost.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function New-TestHost {
    param([string]$Name, [string]$State = 'Connected', [decimal]$UsedGB, [decimal]$TotalGB)
    New-Object psobject -Property @{
        Name            = $Name
        ConnectionState = $State
        MemoryUsageGB   = $UsedGB
        MemoryTotalGB   = $TotalGB
    }
}

Describe 'Select-VAPlacementHost' {

    $config = Read-VAConfig -Path $examplePath

    Context 'the fixture hosts' {
        Mock Get-VMHost {
            New-TestHost -Name 'esx03.lab.local' -UsedGB 84 -TotalGB 96
            New-TestHost -Name 'esx02.lab.local' -UsedGB 28 -TotalGB 64
            New-TestHost -Name 'esx01.lab.local' -UsedGB 10 -TotalGB 64
        }

        It 'picks the least loaded host' {
            (Select-VAPlacementHost -Config $config -MemoryMB 4096).Name | Should Be 'esx01.lab.local'
        }
        It 'asks for the hosts of the configured cluster' {
            Assert-MockCalled Get-VMHost -ParameterFilter { @($Location) -contains 'Lab-Cluster' }
        }
    }

    Context 'maintenance, disconnected and overloaded hosts' {
        Mock Get-VMHost {
            New-TestHost -Name 'esx01.lab.local' -State 'Maintenance' -UsedGB 0 -TotalGB 64
            New-TestHost -Name 'esx02.lab.local' -State 'Disconnected' -UsedGB 0 -TotalGB 64
            New-TestHost -Name 'esx03.lab.local' -UsedGB 84 -TotalGB 96
            New-TestHost -Name 'esx04.lab.local' -State 'NotResponding' -UsedGB 1 -TotalGB 64
            New-TestHost -Name 'esx05.lab.local' -UsedGB 40 -TotalGB 64
        }

        It 'skips them and picks the remaining host' {
            (Select-VAPlacementHost -Config $config -MemoryMB 4096).Name | Should Be 'esx05.lab.local'
        }
    }

    Context 'projected load against hostMaxMemoryPct' {
        # 64 GB host with 50 GB used: 4096 MB more gives 84.375 %, 5120 MB more gives 85.9375 %.
        Mock Get-VMHost { New-TestHost -Name 'esx01.lab.local' -UsedGB 50 -TotalGB 64 }

        It 'accepts a VM that keeps the host at or below the limit' {
            (Select-VAPlacementHost -Config $config -MemoryMB 4096).Name | Should Be 'esx01.lab.local'
        }
        It 'rejects a VM that would push the host over the limit' {
            { Select-VAPlacementHost -Config $config -MemoryMB 5120 } | Should Throw 'no host has capacity'
        }
    }

    Context 'nothing fits' {
        Mock Get-VMHost {
            New-TestHost -Name 'esx01.lab.local' -State 'Maintenance' -UsedGB 0 -TotalGB 64
            New-TestHost -Name 'esx03.lab.local' -UsedGB 84 -TotalGB 96
        }

        It 'throws "no host has capacity" with the requested memory' {
            { Select-VAPlacementHost -Config $config -MemoryMB 4096 } | Should Throw 'no host has capacity for 4096 MB'
        }
    }

    Context 'equal load' {
        Mock Get-VMHost {
            New-TestHost -Name 'esx02.lab.local' -UsedGB 16 -TotalGB 64
            New-TestHost -Name 'esx01.lab.local' -UsedGB 16 -TotalGB 64
        }

        It 'breaks the tie by host name' {
            (Select-VAPlacementHost -Config $config -MemoryMB 4096).Name | Should Be 'esx01.lab.local'
        }
    }

    Context 'load is a percentage, not absolute memory' {
        # esx01: 20/64 = 31.25 %; esx03: 24/96 = 25 %.
        Mock Get-VMHost {
            New-TestHost -Name 'esx01.lab.local' -UsedGB 20 -TotalGB 64
            New-TestHost -Name 'esx03.lab.local' -UsedGB 24 -TotalGB 96
        }

        It 'picks the host with the lower memory percentage' {
            (Select-VAPlacementHost -Config $config -MemoryMB 4096).Name | Should Be 'esx03.lab.local'
        }
    }

    Context 'an explicit cluster' {
        Mock Get-VMHost { New-TestHost -Name 'esx09.lab.local' -UsedGB 1 -TotalGB 64 }

        $null = Select-VAPlacementHost -Config $config -MemoryMB 4096 -Cluster 'Other-Cluster'

        It 'uses -Cluster instead of the configured cluster' {
            Assert-MockCalled Get-VMHost -Times 1 -Exactly -ParameterFilter { @($Location) -contains 'Other-Cluster' }
        }
    }
}
