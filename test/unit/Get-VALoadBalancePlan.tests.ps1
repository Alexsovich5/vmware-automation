$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Public/Get-VALoadBalancePlan.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

# A cluster layout: host name -> total GB, and VM rows (Name, Host, MemoryGB, PowerState).
# The mocks below derive Get-VMHost MemoryUsageGB from the powered-on VMs, as vCenter would.
function New-TestLayout {
    param([hashtable]$HostTotalGB, [object[]]$VMs)
    $global:VALayout = New-Object psobject -Property @{ Hosts = $HostTotalGB; VMs = $VMs }
}

function New-TestVMRow {
    param([string]$Name, [string]$VMHost, [decimal]$MemoryGB, [string]$PowerState = 'PoweredOn')
    New-Object psobject -Property @{ Name = $Name; Host = $VMHost; MemoryGB = $MemoryGB; PowerState = $PowerState }
}

function Get-TestLayoutHost {
    foreach ($name in @($global:VALayout.Hosts.Keys | Sort-Object)) {
        $used = [decimal]0
        foreach ($vm in @($global:VALayout.VMs | Where-Object { $_.Host -eq $name -and $_.PowerState -eq 'PoweredOn' })) {
            $used += $vm.MemoryGB
        }
        New-Object psobject -Property @{
            Name = $name; ConnectionState = 'Connected'
            MemoryTotalGB = [decimal]$global:VALayout.Hosts[$name]; MemoryUsageGB = $used
        }
    }
}

function Get-TestLayoutVM {
    foreach ($row in @($global:VALayout.VMs)) {
        New-Object psobject -Property @{
            Name = $row.Name; PowerState = $row.PowerState; MemoryGB = $row.MemoryGB
            MemoryMB = $row.MemoryGB * 1024; VMHost = (New-Object psobject -Property @{ Name = $row.Host })
        }
    }
}

# The fixture's Lab-Cluster: esx01 10/64 GB, esx02 28/64 GB, esx03 84/96 GB.
function Set-LabLayout {
    New-TestLayout -HostTotalGB @{ 'esx01.lab.local' = 64; 'esx02.lab.local' = 64; 'esx03.lab.local' = 96 } -VMs @(
        (New-TestVMRow 'dc01' 'esx01.lab.local' 4),
        (New-TestVMRow 'web-01' 'esx01.lab.local' 4),
        (New-TestVMRow 'test-01' 'esx01.lab.local' 2),
        (New-TestVMRow 'vcsa' 'esx02.lab.local' 8),
        (New-TestVMRow 'web-02' 'esx02.lab.local' 4),
        (New-TestVMRow 'app-idle01' 'esx02.lab.local' 16),
        (New-TestVMRow 'db01' 'esx03.lab.local' 32),
        (New-TestVMRow 'app01' 'esx03.lab.local' 16),
        (New-TestVMRow 'rpt01' 'esx03.lab.local' 12),
        (New-TestVMRow 'app-busy01' 'esx03.lab.local' 8),
        (New-TestVMRow 'app03' 'esx03.lab.local' 8),
        (New-TestVMRow 'build01' 'esx03.lab.local' 8),
        (New-TestVMRow 'old-01' 'esx03.lab.local' 8 'PoweredOff')
    )
}

Describe 'Get-VALoadBalancePlan' {

    Context 'the command' {
        $command = Get-Command Get-VALoadBalancePlan

        It 'takes -Config' {
            $command.Parameters.ContainsKey('Config') | Should Be $true
        }
    }

    Context 'a balanced cluster' {
        $config = Get-TestConfig
        New-TestLayout -HostTotalGB @{ 'h1' = 64; 'h2' = 64 } -VMs @(
            (New-TestVMRow 'a' 'h1' 16), (New-TestVMRow 'b' 'h1' 8),
            (New-TestVMRow 'c' 'h2' 16), (New-TestVMRow 'd' 'h2' 4)
        )
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'returns an empty plan when the spread is under thresholdPct' {
            $plan.Count | Should Be 0
        }
        It 'reads host and VM inventory from the configured cluster' {
            Assert-MockCalled Get-VMHost -Times 1 -ParameterFilter { $Location -eq 'Lab-Cluster' }
            Assert-MockCalled Get-VM -Times 1 -ParameterFilter { $Location -eq 'Lab-Cluster' }
        }
    }

    Context 'the fixture cluster' {
        $config = Get-TestConfig
        Set-LabLayout
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'moves app-busy01, app03 and build01, smallest first with names breaking ties' {
            (@($plan | ForEach-Object { $_.VM }) -join ',') | Should Be 'app-busy01,app03,build01'
        }
        It 'moves each from esx03 to esx01' {
            foreach ($move in $plan) {
                $move.Source | Should Be 'esx03.lab.local'
                $move.Destination | Should Be 'esx01.lab.local'
            }
        }
        It 'reports the spread 71.875 -> 51.04 -> 30.21 -> 18.75' {
            $plan[0].SpreadBefore | Should Be 71.88
            $plan[0].SpreadAfter | Should Be 51.04
            $plan[1].SpreadBefore | Should Be 51.04
            $plan[1].SpreadAfter | Should Be 30.21
            $plan[2].SpreadBefore | Should Be 30.21
            $plan[2].SpreadAfter | Should Be 18.75
        }
        It 'lowers the spread on every move' {
            foreach ($move in $plan) {
                ($move.SpreadAfter -lt $move.SpreadBefore) | Should Be $true
            }
        }
        It 'numbers the moves and carries the VM size' {
            (@($plan | ForEach-Object { $_.Order }) -join ',') | Should Be '1,2,3'
            $plan[0].MemoryGB | Should Be 8
        }
        It 'never plans a powered-off VM' {
            (@($plan | ForEach-Object { $_.VM }) -contains 'old-01') | Should Be $false
        }
        It 'returns Order, VM, MemoryGB, Source, Destination, SpreadBefore and SpreadAfter' {
            (@($plan[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') |
                Should Be 'Order,VM,MemoryGB,Source,Destination,SpreadBefore,SpreadAfter'
        }
    }

    Context 'maxMigrations' {
        $config = Get-TestConfig
        $config.loadBalance.maxMigrations = 2
        Set-LabLayout
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'stops at the cap even though the spread is still over the threshold' {
            $plan.Count | Should Be 2
            $plan[1].SpreadAfter | Should Be 30.21
        }
    }

    Context 'excludeVMs' {
        $config = Get-TestConfig
        $config.loadBalance.excludeVMs = @('vcsa', 'APP-BUSY01')
        Set-LabLayout
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)
        $names = @($plan | ForEach-Object { $_.VM })

        It 'never moves an excluded VM, matching names case-insensitively' {
            ($names -contains 'app-busy01') | Should Be $false
        }
        It 'moves the next smallest VMs instead' {
            ($names -join ',') | Should Be 'app03,build01,rpt01'
            $plan[2].SpreadAfter | Should Be 15.63
        }
    }

    Context 'destination headroom' {
        $config = Get-TestConfig
        $config.loadBalance.destMaxMemoryPct = 60
        $config.loadBalance.thresholdPct = 5
        $config.loadBalance.maxMigrations = 10
        # h1 at 87.5%, h2 at 50%: one 8 GB move lands h2 on 62.5%, over the 60% limit.
        New-TestLayout -HostTotalGB @{ 'h1' = 64; 'h2' = 64 } -VMs @(
            (New-TestVMRow 'big' 'h1' 48), (New-TestVMRow 'small' 'h1' 8),
            (New-TestVMRow 'other' 'h2' 32)
        )
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'skips a move that would push the destination over destMaxMemoryPct' {
            $plan.Count | Should Be 0
        }
    }

    Context 'a move that would make the destination the new hottest host' {
        $config = Get-TestConfig
        $config.loadBalance.thresholdPct = 5
        $config.loadBalance.maxMigrations = 10
        # h1 at 64%, h2 at 50%. Moving tiny gives 60% / 54%. After that, moving a or b would put
        # h2 at 84%, under destMaxMemoryPct but hotter than h1 ever was, so the spread would widen.
        New-TestLayout -HostTotalGB @{ 'h1' = 100; 'h2' = 100 } -VMs @(
            (New-TestVMRow 'a' 'h1' 30), (New-TestVMRow 'b' 'h1' 30), (New-TestVMRow 'tiny' 'h1' 4),
            (New-TestVMRow 'c' 'h2' 50)
        )
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'only plans moves that narrow the spread' {
            (@($plan | ForEach-Object { $_.VM }) -join ',') | Should Be 'tiny'
            $plan[0].SpreadBefore | Should Be 14
            $plan[0].SpreadAfter | Should Be 6
        }
    }

    Context 'powered-off VMs' {
        $config = Get-TestConfig
        # The only VM on the hot host that could narrow the spread is powered off.
        New-TestLayout -HostTotalGB @{ 'h1' = 64; 'h2' = 64 } -VMs @(
            (New-TestVMRow 'busy' 'h1' 40), (New-TestVMRow 'parked' 'h1' 8 'PoweredOff'),
            (New-TestVMRow 'other' 'h2' 4)
        )
        Mock Get-VMHost { Get-TestLayoutHost }
        Mock Get-VM { Get-TestLayoutVM }

        $plan = @(Get-VALoadBalancePlan -Config $config)

        It 'ignores them' {
            (@($plan | ForEach-Object { $_.VM }) -contains 'parked') | Should Be $false
            $plan.Count | Should Be 0
        }
    }
}
