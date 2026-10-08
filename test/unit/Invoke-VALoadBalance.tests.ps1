$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Public/Get-VALoadBalancePlan.ps1')
. (Join-Path $src 'Public/Invoke-VALoadBalance.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function New-TestMove {
    param([int]$Order, [string]$VM, [string]$Source, [string]$Destination, [double]$Before, [double]$After)
    New-Object psobject -Property ([ordered]@{
        Order = $Order; VM = $VM; MemoryGB = 8; Source = $Source; Destination = $Destination
        SpreadBefore = $Before; SpreadAfter = $After
    })
}

function Get-TestPlan {
    @(
        (New-TestMove 1 'app-busy01' 'esx03.lab.local' 'esx01.lab.local' 71.88 51.04),
        (New-TestMove 2 'app03' 'esx03.lab.local' 'esx01.lab.local' 51.04 30.21)
    )
}

Describe 'Invoke-VALoadBalance' {

    Context 'the command' {
        $command = Get-Command Invoke-VALoadBalance

        It 'supports -WhatIf and -Confirm' {
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
        It 'takes -Config and an optional -Plan' {
            $command.Parameters.ContainsKey('Config') | Should Be $true
            $command.Parameters.ContainsKey('Plan') | Should Be $true
        }
    }

    Context 'carrying out the computed plan' {
        $config = Get-TestConfig
        $global:VAMoved = @()
        Mock Get-VALoadBalancePlan { Get-TestPlan }
        Mock Move-VM { $global:VAMoved += ('{0}>{1}' -f @($VM)[0], $Destination) }

        $rows = @(Invoke-VALoadBalance -Config $config -Confirm:$false)

        It 'builds the plan from the config' {
            Assert-MockCalled Get-VALoadBalancePlan -Times 1 -Exactly
        }
        It 'moves each VM to its destination, in plan order, without prompting' {
            ($global:VAMoved -join ',') | Should Be 'app-busy01>esx01.lab.local,app03>esx01.lab.local'
            Assert-MockCalled Move-VM -Times 2 -Exactly -ParameterFilter { $PSBoundParameters['Confirm'] -eq $false }
        }
        It 'returns a Moved row per move' {
            $rows.Count | Should Be 2
            (@($rows | ForEach-Object { $_.Action }) -join ',') | Should Be 'Moved,Moved'
            $rows[0].VM | Should Be 'app-busy01'
            $rows[0].Source | Should Be 'esx03.lab.local'
            $rows[0].Destination | Should Be 'esx01.lab.local'
            $rows[1].SpreadAfter | Should Be 30.21
        }
        It 'returns Order, VM, Source, Destination, SpreadBefore, SpreadAfter and Action' {
            (@($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') |
                Should Be 'Order,VM,Source,Destination,SpreadBefore,SpreadAfter,Action'
        }
        It 'logs each migration' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'app-busy01'
        }
    }

    Context 'a plan passed in' {
        $config = Get-TestConfig
        Mock Get-VALoadBalancePlan { Get-TestPlan }
        Mock Move-VM {}

        $rows = @(Invoke-VALoadBalance -Config $config -Plan @(New-TestMove 1 'build01' 'esx03.lab.local' 'esx02.lab.local' 30 20) -Confirm:$false)

        It 'uses it instead of planning again' {
            Assert-MockCalled Get-VALoadBalancePlan -Times 0 -Exactly
            Assert-MockCalled Move-VM -Times 1 -Exactly -ParameterFilter { @($VM)[0] -eq 'build01' -and $Destination -eq 'esx02.lab.local' }
            $rows[0].VM | Should Be 'build01'
        }
    }

    Context 'an empty plan' {
        $config = Get-TestConfig
        Mock Get-VALoadBalancePlan {}
        Mock Move-VM {}

        $rows = @(Invoke-VALoadBalance -Config $config -Confirm:$false)

        It 'moves nothing and returns nothing' {
            Assert-MockCalled Move-VM -Times 0 -Exactly
            $rows.Count | Should Be 0
        }
        It 'logs that the cluster is balanced' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'balanced'
        }
    }

    Context 'a failed migration' {
        $config = Get-TestConfig
        Mock Get-VALoadBalancePlan { Get-TestPlan }
        Mock Move-VM { throw 'The operation is not allowed in the current state.' }

        It 'stops at the first failure' {
            { Invoke-VALoadBalance -Config $config -Confirm:$false } | Should Throw 'not allowed'
            Assert-MockCalled Move-VM -Times 1 -Exactly
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Mock Get-VALoadBalancePlan { Get-TestPlan }
        Mock Move-VM {}

        $rows = @(Invoke-VALoadBalance -Config $config -WhatIf)

        It 'never calls Move-VM' {
            Assert-MockCalled Move-VM -Times 0 -Exactly
        }
        It 'returns WouldMove rows' {
            (@($rows | ForEach-Object { $_.Action }) -join ',') | Should Be 'WouldMove,WouldMove'
        }
    }
}
