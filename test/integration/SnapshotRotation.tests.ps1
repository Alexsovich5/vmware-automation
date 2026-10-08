$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Invoke-SnapshotRotation.ps1'

function Read-StateFile {
    (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
}

function Get-StateSnapshotName {
    param([psobject]$State, [string]$VM)
    @($State.snapshots | Where-Object { $_.vm -eq $VM } | ForEach-Object { $_.name })
}

# Runs the entry script in its own non-interactive pwsh process, as a scheduler would. Its
# stderr is captured as output, so the runner's 'Stop' preference must not turn it into a throw.
function Invoke-RotationScript {
    param([string[]]$Argument)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File $script @Argument 2>&1
    New-Object psobject -Property @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

Describe 'scripts/Invoke-SnapshotRotation.ps1' {

    Context 'the daily policy at FAKEVI_NOW' {
        $configPath = New-FakeViState
        $run = Invoke-RotationScript -Argument @('-ConfigPath', $configPath)
        $state = Read-StateFile
        $web01 = @(Get-StateSnapshotName -State $state -VM 'web-01')
        $web02 = @(Get-StateSnapshotName -State $state -VM 'web-02')
        $web01Auto = @($state.snapshots | Where-Object { $_.vm -eq 'web-01' -and $_.name -like 'auto-daily-*' })

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'leaves web-01 with five auto snapshots: the new one and those 1, 2, 4 and 6 days old' {
            $web01Auto.Count | Should Be 5
            ($web01 -contains 'auto-daily-20140315-0200') | Should Be $true
            foreach ($kept in @('auto-daily-20140314-0200', 'auto-daily-20140313-0200', 'auto-daily-20140311-0200', 'auto-daily-20140309-0200')) {
                ($web01 -contains $kept) | Should Be $true
            }
        }
        It 'prunes the 8- and 10-day-old auto snapshots' {
            ($web01 -contains 'auto-daily-20140307-0200') | Should Be $false
            ($web01 -contains 'auto-daily-20140305-0200') | Should Be $false
        }
        It 'gives web-02 its first snapshot' {
            $web02.Count | Should Be 1
            $web02[0] | Should Be 'auto-daily-20140315-0200'
        }
        It 'keeps the manual pre-patch snapshot and reports it as stale' {
            ($web01 -contains 'pre-patch') | Should Be $true
            $run.Output | Should Match 'pre-patch\s+Stale'
        }
        It 'does not snapshot VMs outside the policy' {
            @($state.snapshots | Where-Object { $_.vm -notlike 'web-*' }).Count | Should Be 0
        }
        It 'logs to the test drive' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'auto-daily-20140305-0200'
        }
    }

    Context '-Now passed through' {
        $configPath = New-FakeViState
        $run = Invoke-RotationScript -Argument @('-ConfigPath', $configPath, '-PolicyName', 'daily', '-Now', '2014-03-16T02:00:00')
        $state = Read-StateFile

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'names the new snapshot from -Now' {
            ((Get-StateSnapshotName -State $state -VM 'web-02') -join ',') | Should Be 'auto-daily-20140316-0200'
        }
    }

    Context '-WhatIf' {
        $configPath = New-FakeViState
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $run = Invoke-RotationScript -Argument @('-ConfigPath', $configPath, '-WhatIf')

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'leaves the state file unchanged' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        It 'reports the planned changes' {
            $run.Output | Should Match 'WouldCreate'
            $run.Output | Should Match 'WouldRemove'
        }
    }

    Context 'an unknown policy' {
        $configPath = New-FakeViState
        $run = Invoke-RotationScript -Argument @('-ConfigPath', $configPath, '-PolicyName', 'weekly')

        It 'exits non-zero' {
            ($run.ExitCode -ne 0) | Should Be $true
        }
        It 'names the policy in the error' {
            $run.Output | Should Match 'weekly'
        }
    }
}
