$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Read-VAHardeningBaseline.ps1')
. (Join-Path $src 'Public/Test-VAHardening.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

# A small baseline with one check of each kind.
function Get-TestBaseline {
    @'
{
  "host": {
    "advancedSettings": [
      { "id": "ESXi.set-shell-timeout",      "name": "UserVars.ESXiShellTimeOut", "value": 900 },
      { "id": "ESXi.config-persistent-logs", "name": "Syslog.global.logDir",      "notValue": "[] /scratch/log" }
    ],
    "services": [ { "id": "ESXi.disable-ssh", "key": "TSM-SSH", "running": false, "policy": "off" } ],
    "ntp":      { "id": "ESXi.config-ntp", "minServers": 1 }
  },
  "vm": {
    "advancedSettings": [
      { "id": "VM.disable-console-copy", "name": "isolation.tools.copy.disable", "value": "TRUE" },
      { "id": "VM.limit-setinfo-size",   "name": "tools.setInfo.sizeLimit",      "value": "1048576" }
    ]
  }
}
'@ | ConvertFrom-Json
}

function New-TestHost {
    param([string]$Name)
    New-Object psobject -Property @{ Name = $Name }
}

function New-TestVM {
    param([string]$Name)
    New-Object psobject -Property @{ Name = $Name; PowerState = 'PoweredOn' }
}

function New-TestSetting {
    param([object]$Entity, [string]$Name, [object]$Value)
    New-Object psobject -Property @{ Entity = $Entity; Name = $Name; Value = $Value }
}

function New-TestService {
    param([string]$Key, [bool]$Running, [string]$Policy)
    New-Object psobject -Property @{ Key = $Key; Label = $Key; Running = $Running; Policy = $Policy }
}

function Get-Row {
    param([object[]]$Rows, [string]$Entity, [string]$CheckId)
    @($Rows | Where-Object { $_.Entity -eq $Entity -and $_.CheckId -eq $CheckId })
}

Describe 'Test-VAHardening' {

    Context 'the command' {
        $command = Get-Command Test-VAHardening

        It 'takes -Config and an optional -Baseline' {
            $command.Parameters.ContainsKey('Config') | Should Be $true
            $command.Parameters.ContainsKey('Baseline') | Should Be $true
        }
    }

    Context 'a mixed host and VM' {
        $config = Get-TestConfig
        Mock Get-VMHost { New-TestHost 'esx01.lab.local' }
        Mock Get-VM { New-TestVM 'web-01' }
        Mock Get-AdvancedSetting {
            $name = @($Entity)[0].Name
            if ($name -eq 'esx01.lab.local') {
                New-TestSetting @($Entity)[0] 'UserVars.ESXiShellTimeOut' 0
                New-TestSetting @($Entity)[0] 'Syslog.global.logDir' '[] /scratch/log'
            }
            else {
                New-TestSetting @($Entity)[0] 'isolation.tools.copy.disable' 'true'
            }
        }
        Mock Get-VMHostService { New-TestService 'TSM-SSH' $true 'on' }
        Mock Get-VMHostNtpServer { }

        $rows = @(Test-VAHardening -Config $config -Baseline (Get-TestBaseline))

        It 'returns one row per check and entity' {
            $rows.Count | Should Be 6
            (@($rows | Where-Object { $_.EntityType -eq 'VMHost' }).Count) | Should Be 4
            (@($rows | Where-Object { $_.EntityType -eq 'VM' }).Count) | Should Be 2
        }
        It 'returns EntityType, Entity, CheckId, Setting, Expected, Actual and Compliant' {
            (@($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') |
                Should Be 'EntityType,Entity,CheckId,Setting,Expected,Actual,Compliant'
        }
        It 'compares value checks as strings, so 0 is not 900' {
            $r = Get-Row $rows 'esx01.lab.local' 'ESXi.set-shell-timeout'
            $r[0].Compliant | Should Be $false
            $r[0].Expected | Should Be '900'
            $r[0].Actual | Should Be '0'
            $r[0].Setting | Should Be 'UserVars.ESXiShellTimeOut'
        }
        It 'compares value checks case-insensitively, so true matches TRUE' {
            $r = Get-Row $rows 'web-01' 'VM.disable-console-copy'
            $r[0].Compliant | Should Be $true
            $r[0].Actual | Should Be 'true'
        }
        It 'fails a notValue check when the value equals the forbidden default' {
            $r = Get-Row $rows 'esx01.lab.local' 'ESXi.config-persistent-logs'
            $r[0].Compliant | Should Be $false
            $r[0].Actual | Should Be '[] /scratch/log'
        }
        It 'reports a missing VM setting as non-compliant with Actual null' {
            $r = Get-Row $rows 'web-01' 'VM.limit-setinfo-size'
            $r[0].Compliant | Should Be $false
            $r[0].Actual | Should BeNullOrEmpty
            ($null -eq $r[0].Actual) | Should Be $true
        }
        It 'reports a running SSH service as non-compliant' {
            $r = Get-Row $rows 'esx01.lab.local' 'ESXi.disable-ssh'
            $r[0].Compliant | Should Be $false
            $r[0].Setting | Should Be 'TSM-SSH'
            $r[0].Actual | Should Match 'True'
        }
        It 'reports zero NTP servers as non-compliant' {
            $r = Get-Row $rows 'esx01.lab.local' 'ESXi.config-ntp'
            $r[0].Compliant | Should Be $false
        }
        It 'logs a summary' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'non-compliant'
        }
    }

    Context 'a compliant host' {
        $config = Get-TestConfig
        Mock Get-VMHost { New-TestHost 'esx02.lab.local' }
        Mock Get-VM { }
        Mock Get-AdvancedSetting {
            New-TestSetting @($Entity)[0] 'UserVars.ESXiShellTimeOut' 900
            New-TestSetting @($Entity)[0] 'Syslog.global.logDir' '[ds-sata01] logs/esx02'
        }
        Mock Get-VMHostService {
            New-TestService 'TSM' $false 'off'
            New-TestService 'TSM-SSH' $false 'off'
        }
        Mock Get-VMHostNtpServer { 'ntp1.lab.local' }

        $rows = @(Test-VAHardening -Config $config -Baseline (Get-TestBaseline))

        It 'passes every check' {
            $rows.Count | Should Be 4
            @($rows | Where-Object { -not $_.Compliant }).Count | Should Be 0
        }
        It 'passes a notValue check with any other value' {
            (Get-Row $rows 'esx02.lab.local' 'ESXi.config-persistent-logs')[0].Compliant | Should Be $true
        }
        It 'checks the configured cluster' {
            Assert-MockCalled Get-VMHost -Times 1 -ParameterFilter { @($Location)[0] -eq 'Lab-Cluster' }
            Assert-MockCalled Get-VM -Times 1 -ParameterFilter { @($Location)[0] -eq 'Lab-Cluster' }
        }
    }

    Context 'an SSH service that is stopped but still starts with the host' {
        $config = Get-TestConfig
        Mock Get-VMHost { New-TestHost 'esx03.lab.local' }
        Mock Get-VM { }
        Mock Get-AdvancedSetting { }
        Mock Get-VMHostService { New-TestService 'TSM-SSH' $false 'on' }
        Mock Get-VMHostNtpServer { 'ntp1.lab.local' }

        $rows = @(Test-VAHardening -Config $config -Baseline (Get-TestBaseline))

        It 'is non-compliant because of the policy' {
            (Get-Row $rows 'esx03.lab.local' 'ESXi.disable-ssh')[0].Compliant | Should Be $false
        }
    }

    Context 'the example config and baseline file' {
        $config = Get-TestConfig
        Mock Get-VMHost { New-TestHost 'esx01.lab.local' }
        Mock Get-VM { New-TestVM 'dc01' }
        Mock Get-AdvancedSetting { }
        Mock Get-VMHostService { }
        Mock Get-VMHostNtpServer { }

        $rows = @(Test-VAHardening -Config $config)

        It 'resolves hardeningBaseline to an existing file' {
            $config.hardeningBaseline | Should Exist
            $config.hardeningBaseline | Should Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'config/hardening-baseline.json')))
        }
        It 'loads it when -Baseline is omitted' {
            $ids = @($rows | ForEach-Object { $_.CheckId })
            foreach ($id in @('ESXi.set-shell-interactive-timeout', 'ESXi.set-shell-timeout', 'ESXi.config-persistent-logs',
                              'ESXi.enable-bpdu-filter', 'ESXi.disable-ssh', 'ESXi.config-ntp',
                              'VM.disable-console-copy', 'VM.disable-console-paste', 'VM.disable-disk-shrinking-shrink',
                              'VM.disable-disk-shrinking-wiper', 'VM.limit-console-connection', 'VM.limit-setinfo-size')) {
                ($ids -contains $id) | Should Be $true
            }
            $rows.Count | Should Be 12
        }
    }

    Context 'a missing baseline file' {
        $config = Get-TestConfig
        $config.hardeningBaseline = Join-Path $TestDrive 'nope.json'
        Mock Get-VMHost { }
        Mock Get-VM { }

        It 'throws an error naming the file' {
            { Test-VAHardening -Config $config } | Should Throw 'nope.json'
        }
    }
}
