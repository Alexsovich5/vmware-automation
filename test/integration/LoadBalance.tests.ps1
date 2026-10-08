$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Invoke-LoadBalance.ps1'

function Read-StateFile {
    (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
}

# Host memory % from the state file: powered-on VM memory over host memory, as Get-VMHost reports it.
function Get-StateHostPct {
    param([psobject]$State)
    $pct = @{}
    foreach ($vmHost in @($State.hosts)) {
        $used = 0
        foreach ($vm in @($State.vms | Where-Object { $_.host -eq $vmHost.name -and $_.powerState -eq 'PoweredOn' })) {
            $used += [double]$vm.memoryMB
        }
        $pct[$vmHost.name] = 100 * $used / [double]$vmHost.memoryTotalMB
    }
    $pct
}

function Get-StateSpread {
    param([psobject]$State)
    $values = @((Get-StateHostPct -State $State).Values | Sort-Object)
    [math]::Round($values[-1] - $values[0], 2)
}

function Get-StateVMHost {
    param([psobject]$State, [string]$VM)
    @($State.vms | Where-Object { $_.name -eq $VM })[0].host
}

# Runs the entry script in its own non-interactive pwsh process; stderr is captured as output.
function Invoke-LoadBalanceScript {
    param([string[]]$Argument)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File $script @Argument 2>&1
    New-Object psobject -Property @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

Describe 'scripts/Invoke-LoadBalance.ps1' {

    Context 'the fixture cluster' {
        $configPath = New-FakeViState
        $spreadBefore = Get-StateSpread -State (Read-StateFile)
        $run = Invoke-LoadBalanceScript -Argument @('-ConfigPath', $configPath)
        $state = Read-StateFile

        It 'starts with a 71.88% host memory spread' {
            $spreadBefore | Should Be 71.88
        }
        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'leaves a host memory spread of 18.75%, below the 20% threshold' {
            Get-StateSpread -State $state | Should Be 18.75
        }
        It 'moves app-busy01, app03 and build01 to esx01' {
            foreach ($vm in @('app-busy01', 'app03', 'build01')) {
                Get-StateVMHost -State $state -VM $vm | Should Be 'esx01.lab.local'
            }
        }
        It 'leaves the excluded and powered-off VMs where they were' {
            Get-StateVMHost -State $state -VM 'vcsa' | Should Be 'esx02.lab.local'
            Get-StateVMHost -State $state -VM 'old-01' | Should Be 'esx03.lab.local'
        }
        It 'prints the moves' {
            $run.Output | Should Match 'app-busy01'
            $run.Output | Should Match 'Moved'
        }
        It 'logs to the test drive' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'build01'
        }
    }

    Context 'a second run' {
        $configPath = New-FakeViState
        $null = Invoke-LoadBalanceScript -Argument @('-ConfigPath', $configPath)
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $run = Invoke-LoadBalanceScript -Argument @('-ConfigPath', $configPath)

        It 'exits 0 and moves nothing, because the cluster is balanced' {
            $run.ExitCode | Should Be 0
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
    }

    Context '-WhatIf' {
        $configPath = New-FakeViState
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $run = Invoke-LoadBalanceScript -Argument @('-ConfigPath', $configPath, '-WhatIf')

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'leaves the state file unchanged' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        It 'reports the planned moves' {
            $run.Output | Should Match 'WouldMove'
            $run.Output | Should Match 'build01'
        }
    }
}
