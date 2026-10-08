$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$manifestPath = Join-Path $repo 'src/VMwareAutomation/VMwareAutomation.psd1'

function Reset-ProvisionSession {
    Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

function Read-StateFile {
    (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
}

Describe 'Provisioning against FakePowerCLI' {

    Context 'a tpl-centos65 request' {
        Reset-ProvisionSession
        $configPath = New-FakeViState
        $module = Import-Module $manifestPath -Global -Force -PassThru
        $config = & $module { param($Path) Read-VAConfig -Path $Path } $configPath
        & $module { Import-VAPowerCLI }
        $null = Connect-VAvCenter -Config $config

        $result = New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 -Notes 'frontend' -Confirm:$false
        $state = Read-StateFile
        $record = @($state.vms | Where-Object { $_.name -eq 'web-03' })

        It 'returns the new VM powered on' {
            $result.Name | Should Be 'web-03'
            $result.PowerState | Should Be 'PoweredOn'
        }
        It 'adds the VM to the state file' {
            $record.Count | Should Be 1
        }
        It 'leaves it powered on with the requested CPU, memory and notes' {
            $record[0].powerState | Should Be 'PoweredOn'
            $record[0].numCpu | Should Be 2
            $record[0].memoryMB | Should Be 4096
            $record[0].notes | Should Be 'frontend'
        }
        It 'places it on esx01.lab.local and ds-sata01' {
            $record[0].host | Should Be 'esx01.lab.local'
            $record[0].datastore | Should Be 'ds-sata01'
        }
        It 'counts its memory in the host load' {
            (Get-VMHost -Name 'esx01.lab.local').MemoryUsageGB | Should Be 14
        }
        It 'refuses a second VM with the same name' {
            { New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 -Confirm:$false } |
                Should Throw "A VM named 'web-03' already exists"
        }
        Reset-ProvisionSession
    }

    Context '-WhatIf' {
        Reset-ProvisionSession
        $configPath = New-FakeViState
        $module = Import-Module $manifestPath -Global -Force -PassThru
        $config = & $module { param($Path) Read-VAConfig -Path $Path } $configPath
        & $module { Import-VAPowerCLI }
        $null = Connect-VAvCenter -Config $config
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash

        $null = New-VAVirtualMachine -Config $config -Name 'web-04' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 -WhatIf

        It 'leaves the state file unchanged' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        Reset-ProvisionSession
    }
}
