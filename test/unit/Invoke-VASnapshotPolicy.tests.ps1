$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Public/Invoke-VASnapshotPolicy.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'
$now = [datetime]'2014-03-15T02:00:00'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function New-TestVM {
    param([string]$Name)
    New-Object psobject -Property @{ Name = $Name; PowerState = 'PoweredOn' }
}

function New-TestSnapshot {
    param([string]$VM, [string]$Name, [double]$AgeDays)
    New-Object psobject -Property @{
        Name    = $Name
        Created = $now.AddDays(-1 * $AgeDays)
        VM      = (New-TestVM -Name $VM)
        Id      = ('VirtualMachineSnapshot-snapshot-{0}-{1}' -f $VM, $Name)
    }
}

# web-01 and web-02 match the example policy (web-*); app01 does not.
function Get-TestVMs {
    @((New-TestVM 'web-01'), (New-TestVM 'web-02'), (New-TestVM 'app01'))
}

function Get-TestSnapshots {
    @(
        (New-TestSnapshot 'web-01' 'auto-daily-20140314-0200' 1),
        (New-TestSnapshot 'web-01' 'auto-daily-20140313-0200' 2),
        (New-TestSnapshot 'web-01' 'auto-daily-20140311-0200' 4),
        (New-TestSnapshot 'web-01' 'auto-daily-20140309-0200' 6),
        (New-TestSnapshot 'web-01' 'auto-daily-20140307-0200' 8),
        (New-TestSnapshot 'web-01' 'auto-daily-20140305-0200' 10),
        (New-TestSnapshot 'web-01' 'pre-patch' 30),
        (New-TestSnapshot 'web-01' 'pre-upgrade' 3),
        (New-TestSnapshot 'app01' 'auto-daily-20140223-0200' 20),
        (New-TestSnapshot 'app01' 'old-manual' 40)
    )
}

Describe 'Invoke-VASnapshotPolicy' {

    Context 'the command' {
        $command = Get-Command Invoke-VASnapshotPolicy

        It 'supports -WhatIf and -Confirm' {
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
        It 'takes -Now and -PolicyName' {
            $command.Parameters.ContainsKey('Now') | Should Be $true
            $command.Parameters.ContainsKey('PolicyName') | Should Be $true
        }
    }

    Context 'the example daily policy' {
        $config = Get-TestConfig
        Mock Get-VM { Get-TestVMs }
        Mock Get-Snapshot { Get-TestSnapshots }
        Mock New-Snapshot { New-Object psobject -Property @{ Name = $Name; Created = $now } }
        Mock Remove-Snapshot {}

        $rows = @(Invoke-VASnapshotPolicy -Config $config -Now $now -Confirm:$false)
        $created = @($rows | Where-Object { $_.Action -eq 'Created' })
        $removed = @($rows | Where-Object { $_.Action -eq 'Removed' })
        $stale = @($rows | Where-Object { $_.Action -eq 'Stale' })

        It 'names new snapshots auto-<policy>-yyyyMMdd-HHmm from -Now' {
            Assert-MockCalled New-Snapshot -Times 2 -Exactly -ParameterFilter { $Name -ceq 'auto-daily-20140315-0200' }
        }
        It 'snapshots every VM matching the policy wildcard, without prompting' {
            Assert-MockCalled New-Snapshot -Times 1 -Exactly -ParameterFilter {
                @($VM)[0].Name -eq 'web-01' -and $PSBoundParameters['Confirm'] -eq $false
            }
            Assert-MockCalled New-Snapshot -Times 1 -Exactly -ParameterFilter { @($VM)[0].Name -eq 'web-02' }
        }
        It 'takes the memory and quiesce options from the policy' {
            Assert-MockCalled New-Snapshot -Times 2 -Exactly -ParameterFilter { -not $Memory -and -not $Quiesce }
        }
        It 'does not touch VMs outside the wildcard' {
            Assert-MockCalled New-Snapshot -Times 0 -Exactly -ParameterFilter { @($VM)[0].Name -eq 'app01' }
            Assert-MockCalled Remove-Snapshot -Times 0 -Exactly -ParameterFilter { @($Snapshot)[0].VM.Name -eq 'app01' }
            @($rows | Where-Object { $_.VM -eq 'app01' }).Count | Should Be 0
        }
        It 'returns a Created row per matching VM' {
            $created.Count | Should Be 2
            (@($created | ForEach-Object { $_.VM } | Sort-Object) -join ',') | Should Be 'web-01,web-02'
            $created[0].Snapshot | Should Be 'auto-daily-20140315-0200'
            $created[0].Policy | Should Be 'daily'
        }
        It 'removes the auto snapshots older than retentionDays (7)' {
            (@($removed | ForEach-Object { $_.Snapshot }) -join ',') | Should Be 'auto-daily-20140305-0200,auto-daily-20140307-0200'
            Assert-MockCalled Remove-Snapshot -Times 2 -Exactly -ParameterFilter { $PSBoundParameters['Confirm'] -eq $false }
        }
        It 'never removes a manual snapshot' {
            Assert-MockCalled Remove-Snapshot -Times 0 -Exactly -ParameterFilter { @($Snapshot)[0].Name -like 'pre-*' }
        }
        It 'reports a manual snapshot older than staleDays (14) as Stale' {
            $stale.Count | Should Be 1
            $stale[0].VM | Should Be 'web-01'
            $stale[0].Snapshot | Should Be 'pre-patch'
        }
        It 'returns only Policy, VM, Snapshot and Action' {
            (@($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Be 'Policy,VM,Snapshot,Action'
        }
        It 'logs what it did' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'auto-daily-20140305-0200'
        }
    }

    Context 'a VM over maxSnapshots' {
        $config = Get-TestConfig
        $config.snapshots.policies[0].maxSnapshots = 3
        $config.snapshots.policies[0].retentionDays = 30
        $config.snapshots.policies[0].quiesce = $true
        $global:VASnapshotRemoved = @()
        Mock Get-VM { @(New-TestVM 'web-01') }
        Mock Get-Snapshot {
            @(
                (New-TestSnapshot 'web-01' 'auto-daily-20140312-0200' 3),
                (New-TestSnapshot 'web-01' 'auto-daily-20140314-0200' 1),
                (New-TestSnapshot 'web-01' 'auto-daily-20140310-0200' 5),
                (New-TestSnapshot 'web-01' 'auto-daily-20140313-0200' 2)
            )
        }
        Mock New-Snapshot { New-Object psobject -Property @{ Name = $Name; Created = $now } }
        Mock Remove-Snapshot { $global:VASnapshotRemoved += @($Snapshot)[0].Name }

        $rows = @(Invoke-VASnapshotPolicy -Config $config -Now $now -Confirm:$false)

        It 'keeps the newest maxSnapshots, counting the new one' {
            Assert-MockCalled Remove-Snapshot -Times 2 -Exactly
        }
        It 'removes the oldest first' {
            ($global:VASnapshotRemoved -join ',') | Should Be 'auto-daily-20140310-0200,auto-daily-20140312-0200'
            (@($rows | Where-Object { $_.Action -eq 'Removed' } | ForEach-Object { $_.Snapshot }) -join ',') |
                Should Be 'auto-daily-20140310-0200,auto-daily-20140312-0200'
        }
        It 'quiesces when the policy asks for it' {
            Assert-MockCalled New-Snapshot -Times 1 -Exactly -ParameterFilter { $Quiesce }
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Mock Get-VM { Get-TestVMs }
        Mock Get-Snapshot { Get-TestSnapshots }
        Mock New-Snapshot {}
        Mock Remove-Snapshot {}

        $rows = @(Invoke-VASnapshotPolicy -Config $config -Now $now -WhatIf)

        It 'never calls New-Snapshot' {
            Assert-MockCalled New-Snapshot -Times 0 -Exactly
        }
        It 'never calls Remove-Snapshot' {
            Assert-MockCalled Remove-Snapshot -Times 0 -Exactly
        }
        It 'returns WouldCreate, WouldRemove and Stale rows' {
            @($rows | Where-Object { $_.Action -eq 'WouldCreate' }).Count | Should Be 2
            (@($rows | Where-Object { $_.Action -eq 'WouldRemove' } | ForEach-Object { $_.Snapshot }) -join ',') |
                Should Be 'auto-daily-20140305-0200,auto-daily-20140307-0200'
            @($rows | Where-Object { $_.Action -eq 'Stale' }).Count | Should Be 1
            @($rows | Where-Object { $_.Action -eq 'Created' -or $_.Action -eq 'Removed' }).Count | Should Be 0
        }
    }

    Context '-PolicyName' {
        $config = Get-TestConfig
        Mock Get-VM { Get-TestVMs }
        Mock Get-Snapshot {}
        Mock New-Snapshot {}
        Mock Remove-Snapshot {}

        It 'throws for a policy that is not in the config' {
            { Invoke-VASnapshotPolicy -Config $config -PolicyName 'weekly' -Now $now -Confirm:$false } | Should Throw "'weekly'"
        }
        It 'does not snapshot anything for an unknown policy' {
            Assert-MockCalled New-Snapshot -Times 0 -Exactly
        }
    }

    Context 'without -Now' {
        $config = Get-TestConfig
        $savedNow = $env:FAKEVI_NOW
        $env:FAKEVI_NOW = '2014-04-01T23:30:00'
        Mock Get-VM { @(New-TestVM 'web-02') }
        Mock Get-Snapshot {}
        Mock New-Snapshot { New-Object psobject -Property @{ Name = $Name } }
        Mock Remove-Snapshot {}

        $rows = @(Invoke-VASnapshotPolicy -Config $config -Confirm:$false)
        $env:FAKEVI_NOW = $savedNow

        It 'dates the snapshot from Get-VANow' {
            $rows[0].Snapshot | Should Be 'auto-daily-20140401-2330'
        }
    }
}
