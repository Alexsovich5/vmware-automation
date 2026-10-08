$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Invoke-Provisioning.ps1'
$requests = Join-Path $repo 'config/requests.example.csv'

function Read-StateFile {
    (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
}

# Runs the entry script in its own non-interactive pwsh process, as a scheduler would.
function Invoke-ProvisioningScript {
    param([string[]]$Argument)
    $output = & pwsh -NoProfile -NonInteractive -File $script @Argument 2>&1
    New-Object psobject -Property @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

Describe 'scripts/Invoke-Provisioning.ps1' {

    Context 'the example request CSV' {
        $configPath = New-FakeViState
        $run = Invoke-ProvisioningScript -Argument @('-ConfigPath', $configPath, '-RequestPath', $requests)
        $state = Read-StateFile
        $web03 = @($state.vms | Where-Object { $_.name -eq 'web-03' })
        $results = @(Get-ChildItem -Path (Join-Path $TestDrive 'out') -Filter 'provisioning-*.csv' -ErrorAction SilentlyContinue)

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'adds web-03 to the state file, powered on' {
            $web03.Count | Should Be 1
            $web03[0].powerState | Should Be 'PoweredOn'
            $web03[0].numCpu | Should Be 2
            $web03[0].memoryMB | Should Be 4096
        }
        It 'removes test-01 from the state file' {
            @($state.vms | Where-Object { $_.name -eq 'test-01' }).Count | Should Be 0
        }
        It 'writes a result CSV under the output directory' {
            $results.Count | Should Be 1
        }
        It 'records both rows as Succeeded' {
            $rows = @(Import-Csv -Path $results[0].FullName)
            $rows.Count | Should Be 2
            ($rows | Where-Object { $_.Name -eq 'web-03' }).Status | Should Be 'Succeeded'
            ($rows | Where-Object { $_.Name -eq 'web-03' }).Host | Should Be 'esx01.lab.local'
            ($rows | Where-Object { $_.Name -eq 'web-03' }).Datastore | Should Be 'ds-sata01'
            ($rows | Where-Object { $_.Name -eq 'test-01' }).Status | Should Be 'Succeeded'
        }
        It 'logs to the test drive' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'test-01'
        }
    }

    Context 'a batch with a failing row' {
        $configPath = New-FakeViState
        $failing = Join-Path $TestDrive 'failing.csv'
        Set-Content -Path $failing -Encoding UTF8 -Value @(
            'Action,Name,Template,NumCpu,MemoryMB,Datastore,Notes',
            'Deprovision,vcsa,,,,,no',
            'Deprovision,test-01,,,,,retired'
        )
        $run = Invoke-ProvisioningScript -Argument @('-ConfigPath', $configPath, '-RequestPath', $failing)
        $state = Read-StateFile

        It 'exits 1' {
            $run.ExitCode | Should Be 1
        }
        It 'keeps the protected VM' {
            @($state.vms | Where-Object { $_.name -eq 'vcsa' }).Count | Should Be 1
        }
        It 'still removes the other VM' {
            @($state.vms | Where-Object { $_.name -eq 'test-01' }).Count | Should Be 0
        }
    }

    Context 'wildcard and duplicate names in Deprovision rows' {
        # A second VM named web-01 (vCenter allows equal names in different folders).
        $configPath = New-FakeViState -Mutate {
            param($State)
            $copy = (@($State.vms | Where-Object { $_.name -eq 'web-01' })[0]) | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $copy.id = 'VirtualMachine-vm-990'
            $copy.powerState = 'PoweredOff'
            $State.vms = @($State.vms) + $copy
        }
        $wild = Join-Path $TestDrive 'wild.csv'
        Set-Content -Path $wild -Encoding UTF8 -Value @(
            'Action,Name,Template,NumCpu,MemoryMB,Datastore,Notes',
            'Deprovision,dc0*,,,,,matches the protected dc01',
            'Deprovision,old-0?,,,,,matches old-01',
            'Deprovision,web-01,,,,,two VMs carry this name'
        )
        $run = Invoke-ProvisioningScript -Argument @('-ConfigPath', $configPath, '-RequestPath', $wild)
        $state = Read-StateFile
        $results = @(Get-ChildItem -Path (Join-Path $TestDrive 'out') -Filter 'provisioning-*.csv' | Sort-Object LastWriteTime | Select-Object -Last 1)
        $rows = @(Import-Csv -Path $results[0].FullName)

        It 'exits 1' {
            $run.ExitCode | Should Be 1
        }
        It 'keeps the protected dc01 and old-01' {
            @($state.vms | Where-Object { $_.name -eq 'dc01' }).Count | Should Be 1
            @($state.vms | Where-Object { $_.name -eq 'old-01' }).Count | Should Be 1
        }
        It 'keeps both VMs named web-01' {
            @($state.vms | Where-Object { $_.name -eq 'web-01' }).Count | Should Be 2
        }
        It 'records every row as Failed with the reason' {
            @($rows | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 3
            $rows[0].Message | Should Match 'wildcard'
            $rows[1].Message | Should Match 'wildcard'
            $rows[2].Message | Should Match 'ambiguous'
        }
    }

    Context '-WhatIf' {
        $configPath = New-FakeViState
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $run = Invoke-ProvisioningScript -Argument @('-ConfigPath', $configPath, '-RequestPath', $requests, '-WhatIf')
        $results = @(Get-ChildItem -Path (Join-Path $TestDrive 'out') -Filter 'provisioning-*.csv' -ErrorAction SilentlyContinue)

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'leaves the state file unchanged' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        It 'reports every row as Skipped' {
            $rows = @(Import-Csv -Path $results[0].FullName)
            $rows.Count | Should Be 2
            @($rows | Where-Object { $_.Status -eq 'Skipped' }).Count | Should Be 2
        }
    }
}
