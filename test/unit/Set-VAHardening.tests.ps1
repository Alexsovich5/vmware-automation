$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Read-VAHardeningBaseline.ps1')
. (Join-Path $src 'Private/Resolve-VAExactEntity.ps1')
. (Join-Path $src 'Public/Test-VAHardening.ps1')
. (Join-Path $src 'Public/Set-VAHardening.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function Get-TestBaseline {
    @'
{
  "host": {
    "advancedSettings": [
      { "id": "ESXi.set-shell-timeout",      "name": "UserVars.ESXiShellTimeOut", "value": 900 },
      { "id": "ESXi.enable-bpdu-filter",     "name": "Net.BlockGuestBPDU",        "value": 1 },
      { "id": "ESXi.config-persistent-logs", "name": "Syslog.global.logDir",      "notValue": "[] /scratch/log" }
    ],
    "services": [ { "id": "ESXi.disable-ssh", "key": "TSM-SSH", "running": false, "policy": "off" } ],
    "ntp":      { "id": "ESXi.config-ntp", "minServers": 1 }
  },
  "vm": {
    "advancedSettings": [
      { "id": "VM.disable-console-copy",     "name": "isolation.tools.copy.disable", "value": "TRUE" },
      { "id": "VM.limit-console-connection", "name": "RemoteDisplay.maxConnections", "value": "1" }
    ]
  }
}
'@ | ConvertFrom-Json
}

function New-TestRow {
    param([string]$EntityType, [string]$Entity, [string]$CheckId, [string]$Setting, [object]$Expected, [object]$Actual, [bool]$Compliant)
    New-Object psobject -Property ([ordered]@{
        EntityType = $EntityType; Entity = $Entity; CheckId = $CheckId; Setting = $Setting
        Expected = $Expected; Actual = $Actual; Compliant = $Compliant
    })
}

# esx01: shell timeout wrong, BPDU filter fine, logs on scratch, SSH running and on, no NTP.
# web-01: copy.disable missing, maxConnections set to 2.
function Get-TestRows {
    @(
        (New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.set-shell-timeout' 'UserVars.ESXiShellTimeOut' '900' '0' $false),
        (New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.enable-bpdu-filter' 'Net.BlockGuestBPDU' '1' '1' $true),
        (New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.config-persistent-logs' 'Syslog.global.logDir' 'not [] /scratch/log' '[] /scratch/log' $false),
        (New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.disable-ssh' 'TSM-SSH' 'Running=False; Policy=off' 'Running=True; Policy=on' $false),
        (New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.config-ntp' 'NtpServers' 'at least 1' '' $false),
        (New-TestRow 'VM' 'web-01' 'VM.disable-console-copy' 'isolation.tools.copy.disable' 'TRUE' $null $false),
        (New-TestRow 'VM' 'web-01' 'VM.limit-console-connection' 'RemoteDisplay.maxConnections' '1' '2' $false),
        (New-TestRow 'VM' 'dc01' 'VM.disable-console-copy' 'isolation.tools.copy.disable' 'TRUE' 'TRUE' $true)
    )
}

# Mocks for the inventory lookups Set-VAHardening needs to reach the objects it changes.
function Set-InventoryMocks {
    Mock Get-VMHost { New-Object psobject -Property @{ Name = @($Name)[0] } }
    Mock Get-VM { New-Object psobject -Property @{ Name = @($Name)[0] } }
    Mock Get-AdvancedSetting {
        foreach ($n in @($Name)) {
            New-Object psobject -Property @{ Entity = @($Entity)[0]; Name = $n; Value = 'old' }
        }
    }
    Mock Get-VMHostService {
        New-Object psobject -Property @{ Key = 'TSM'; Running = $false; Policy = 'off'; VMHost = @($VMHost)[0] }
        New-Object psobject -Property @{ Key = 'TSM-SSH'; Running = $true; Policy = 'on'; VMHost = @($VMHost)[0] }
    }
}

Describe 'Set-VAHardening' {

    Context 'the command' {
        $command = Get-Command Set-VAHardening

        It 'supports -WhatIf and -Confirm' {
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
        It 'takes -Config and an optional -Baseline' {
            $command.Parameters.ContainsKey('Config') | Should Be $true
            $command.Parameters.ContainsKey('Baseline') | Should Be $true
        }
    }

    Context 'remediating the non-compliant items' {
        $config = Get-TestConfig
        Mock Test-VAHardening { Get-TestRows }
        Set-InventoryMocks
        Mock Set-AdvancedSetting { }
        Mock New-AdvancedSetting { }
        Mock Stop-VMHostService { }
        Mock Set-VMHostService { }

        $rows = @(Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -Confirm:$false)

        It 'sets an existing host setting to the baseline value' {
            Assert-MockCalled Set-AdvancedSetting -Times 1 -Exactly -ParameterFilter {
                @($AdvancedSetting)[0].Name -eq 'UserVars.ESXiShellTimeOut' -and
                @($AdvancedSetting)[0].Entity.Name -eq 'esx01.lab.local' -and "$Value" -eq '900' -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'sets an existing VM setting to the baseline value' {
            Assert-MockCalled Set-AdvancedSetting -Times 1 -Exactly -ParameterFilter {
                @($AdvancedSetting)[0].Name -eq 'RemoteDisplay.maxConnections' -and
                @($AdvancedSetting)[0].Entity.Name -eq 'web-01' -and "$Value" -eq '1'
            }
        }
        It 'creates a missing VM setting' {
            Assert-MockCalled New-AdvancedSetting -Times 1 -Exactly -ParameterFilter {
                @($Entity)[0].Name -eq 'web-01' -and $Name -eq 'isolation.tools.copy.disable' -and "$Value" -eq 'TRUE' -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'leaves compliant items alone' {
            Assert-MockCalled Set-AdvancedSetting -Times 2 -Exactly
            Assert-MockCalled New-AdvancedSetting -Times 1 -Exactly
            Assert-MockCalled Set-AdvancedSetting -Times 0 -Exactly -ParameterFilter { @($AdvancedSetting)[0].Name -eq 'Net.BlockGuestBPDU' }
            Assert-MockCalled Get-VM -Times 0 -Exactly -ParameterFilter { @($Name)[0] -eq 'dc01' }
        }
        It 'stops the SSH service and turns its policy off' {
            Assert-MockCalled Stop-VMHostService -Times 1 -Exactly -ParameterFilter {
                @($HostService)[0].Key -eq 'TSM-SSH' -and $PSBoundParameters['Confirm'] -eq $false
            }
            Assert-MockCalled Set-VMHostService -Times 1 -Exactly -ParameterFilter {
                @($HostService)[0].Key -eq 'TSM-SSH' -and $Policy -eq 'Off' -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'returns a row per non-compliant item' {
            $rows.Count | Should Be 6
            (@($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') |
                Should Be 'EntityType,Entity,CheckId,Setting,Action'
            (@($rows | Where-Object { $_.Action -eq 'Fixed' }).Count) | Should Be 4
        }
        It 'reports NTP and notValue items without changing them' {
            (@($rows | Where-Object { $_.CheckId -eq 'ESXi.config-ntp' })[0].Action) | Should Be 'ReportOnly'
            (@($rows | Where-Object { $_.CheckId -eq 'ESXi.config-persistent-logs' })[0].Action) | Should Be 'ReportOnly'
        }
        It 'logs each change' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'UserVars.ESXiShellTimeOut'
        }
    }

    Context 'SSH stopped but with policy on' {
        $config = Get-TestConfig
        Mock Test-VAHardening {
            New-TestRow 'VMHost' 'esx02.lab.local' 'ESXi.disable-ssh' 'TSM-SSH' 'Running=False; Policy=off' 'Running=False; Policy=on' $false
        }
        Mock Get-VMHost { New-Object psobject -Property @{ Name = @($Name)[0] } }
        Mock Get-VMHostService { New-Object psobject -Property @{ Key = 'TSM-SSH'; Running = $false; Policy = 'on' } }
        Mock Stop-VMHostService { }
        Mock Set-VMHostService { }

        $null = Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -Confirm:$false

        It 'only changes the policy' {
            Assert-MockCalled Stop-VMHostService -Times 0 -Exactly
            Assert-MockCalled Set-VMHostService -Times 1 -Exactly
        }
    }

    Context 'a host name shared by two hosts' {
        $config = Get-TestConfig
        Mock Test-VAHardening {
            New-TestRow 'VMHost' 'esx01.lab.local' 'ESXi.disable-ssh' 'TSM-SSH' 'Running=False; Policy=off' 'Running=True; Policy=on' $false
        }
        Mock Get-VMHost {
            New-Object psobject -Property @{ Name = 'esx01.lab.local'; Id = 'host-10' }
            New-Object psobject -Property @{ Name = 'esx01.lab.local'; Id = 'host-11' }
        }
        Mock Get-VMHostService { New-Object psobject -Property @{ Key = 'TSM-SSH'; Running = $true; Policy = 'on' } }
        Mock Stop-VMHostService { }
        Mock Set-VMHostService { }

        It 'throws instead of stopping a service on an arbitrary host' {
            { Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -Confirm:$false } | Should Throw 'ambiguous'
        }
        It 'changes no service' {
            Assert-MockCalled Stop-VMHostService -Times 0 -Exactly
            Assert-MockCalled Set-VMHostService -Times 0 -Exactly
        }
    }

    Context 'a VM lookup that also returns a similarly named VM' {
        $config = Get-TestConfig
        Mock Test-VAHardening {
            New-TestRow 'VM' 'web-01' 'VM.limit-console-connection' 'RemoteDisplay.maxConnections' '1' '2' $false
        }
        Mock Get-VM {
            New-Object psobject -Property @{ Name = 'web-010'; Id = 'vm-2' }
            New-Object psobject -Property @{ Name = 'web-01'; Id = 'vm-1' }
        }
        Mock Get-AdvancedSetting {
            New-Object psobject -Property @{ Entity = @($Entity)[0]; Name = @($Name)[0]; Value = '2' }
        }
        Mock Set-AdvancedSetting { }

        $null = Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -Confirm:$false

        It 'changes the setting on the VM with exactly that name' {
            Assert-MockCalled Set-AdvancedSetting -Times 1 -Exactly
            Assert-MockCalled Set-AdvancedSetting -Times 1 -Exactly -ParameterFilter { @($AdvancedSetting)[0].Entity.Id -eq 'vm-1' }
        }
    }

    Context 'nothing to fix' {
        $config = Get-TestConfig
        Mock Test-VAHardening { New-TestRow 'VM' 'dc01' 'VM.disable-console-copy' 'isolation.tools.copy.disable' 'TRUE' 'TRUE' $true }
        Set-InventoryMocks
        Mock Set-AdvancedSetting { }
        Mock New-AdvancedSetting { }
        Mock Stop-VMHostService { }
        Mock Set-VMHostService { }

        $rows = @(Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -Confirm:$false)

        It 'changes nothing and returns nothing' {
            Assert-MockCalled Set-AdvancedSetting -Times 0 -Exactly
            Assert-MockCalled New-AdvancedSetting -Times 0 -Exactly
            Assert-MockCalled Stop-VMHostService -Times 0 -Exactly
            Assert-MockCalled Set-VMHostService -Times 0 -Exactly
            $rows.Count | Should Be 0
        }
    }

    Context 'no -Baseline' {
        $config = Get-TestConfig
        Mock Test-VAHardening { }

        $null = Set-VAHardening -Config $config -Confirm:$false

        It 'loads the baseline file from the config and passes it to Test-VAHardening' {
            Assert-MockCalled Test-VAHardening -Times 1 -Exactly -ParameterFilter {
                @($Baseline.vm.advancedSettings).Count -eq 6 -and @($Baseline.host.services)[0].key -eq 'TSM-SSH'
            }
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Mock Test-VAHardening { Get-TestRows }
        Set-InventoryMocks
        Mock Set-AdvancedSetting { }
        Mock New-AdvancedSetting { }
        Mock Stop-VMHostService { }
        Mock Set-VMHostService { }

        $rows = @(Set-VAHardening -Config $config -Baseline (Get-TestBaseline) -WhatIf)

        It 'calls no Set-*, New-* or Stop-* cmdlet' {
            Assert-MockCalled Set-AdvancedSetting -Times 0 -Exactly
            Assert-MockCalled New-AdvancedSetting -Times 0 -Exactly
            Assert-MockCalled Stop-VMHostService -Times 0 -Exactly
            Assert-MockCalled Set-VMHostService -Times 0 -Exactly
        }
        It 'returns WouldFix rows for the items it would change' {
            (@($rows | Where-Object { $_.Action -eq 'WouldFix' }).Count) | Should Be 4
            (@($rows | Where-Object { $_.Action -eq 'Fixed' }).Count) | Should Be 0
        }
    }
}
