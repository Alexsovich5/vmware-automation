$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$manifest = Join-Path $repo 'simulator/FakePowerCLI/FakePowerCLI.psd1'

function Reset-FakeViSession {
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

function Connect-FakeLab {
    $password = ConvertTo-SecureString 'VMware1!' -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential('administrator@vsphere.local', $password)
    FakePowerCLI\Connect-VIServer -Server 'vcsa.lab.local' -Credential $credential
}

Describe 'FakePowerCLI' {

    Context 'module manifest' {
        Reset-FakeViSession
        $module = Import-Module $manifest -PassThru -Force
        $exported = @($module.ExportedFunctions.Keys)

        It 'exports the inventory and connection cmdlets' {
            foreach ($name in @('Connect-VIServer', 'Disconnect-VIServer', 'Get-Cluster', 'Get-VMHost',
                                'Get-VM', 'Get-Template', 'Get-Datastore')) {
                ($exported -contains $name) | Should Be $true
            }
        }
        It 'does not export its state helpers' {
            ($exported -contains 'Get-FakeViState') | Should Be $false
            ($exported -contains 'Save-FakeViState') | Should Be $false
        }
        Reset-FakeViSession
    }

    Context 'before connecting' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force

        It 'Get-VM throws the PowerCLI not-connected error' {
            { FakePowerCLI\Get-VM } | Should Throw 'You are not currently connected to any servers'
        }
        It 'Get-VMHost throws the PowerCLI not-connected error' {
            { FakePowerCLI\Get-VMHost } | Should Throw 'You are not currently connected to any servers'
        }
        It 'leaves DefaultVIServer unset' {
            $global:DefaultVIServer | Should BeNullOrEmpty
        }
        Reset-FakeViSession
    }

    Context 'connecting' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force

        It 'rejects a wrong password' {
            { FakePowerCLI\Connect-VIServer -Server 'vcsa.lab.local' -User 'administrator@vsphere.local' -Password 'wrong' } |
                Should Throw 'incorrect user name or password'
        }
        It 'rejects a wrong user' {
            { FakePowerCLI\Connect-VIServer -Server 'vcsa.lab.local' -User 'root' -Password 'VMware1!' } |
                Should Throw 'incorrect user name or password'
        }
        It 'rejects an unknown server' {
            { FakePowerCLI\Connect-VIServer -Server 'other.lab.local' -User 'administrator@vsphere.local' -Password 'VMware1!' } |
                Should Throw 'other.lab.local'
        }
        It 'stays disconnected after failed logins' {
            $global:DefaultVIServer | Should BeNullOrEmpty
            { FakePowerCLI\Get-VM } | Should Throw 'You are not currently connected to any servers'
        }

        $server = FakePowerCLI\Connect-VIServer -Server 'vcsa.lab.local' -User 'administrator@vsphere.local' -Password 'VMware1!'

        It 'returns a connected server object for -User/-Password' {
            $server.Name | Should Be 'vcsa.lab.local'
            $server.IsConnected | Should Be $true
            $server.User | Should Be 'administrator@vsphere.local'
        }
        It 'sets the global DefaultVIServer' {
            $global:DefaultVIServer.Name | Should Be 'vcsa.lab.local'
        }

        $null = FakePowerCLI\Disconnect-VIServer -Server $server -Confirm:$false

        It 'clears DefaultVIServer on disconnect' {
            $global:DefaultVIServer | Should BeNullOrEmpty
            { FakePowerCLI\Get-VM } | Should Throw 'You are not currently connected to any servers'
        }

        $server = Connect-FakeLab

        It 'accepts a PSCredential' {
            $server.IsConnected | Should Be $true
            $global:DefaultVIServer.Name | Should Be 'vcsa.lab.local'
        }
        Reset-FakeViSession
    }

    Context 'inventory' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force
        $null = Connect-FakeLab

        $clusters = @(FakePowerCLI\Get-Cluster)
        $hosts = @(FakePowerCLI\Get-VMHost -Location 'Lab-Cluster')
        $esx01 = FakePowerCLI\Get-VMHost -Name 'esx01.lab.local'
        $esx02 = FakePowerCLI\Get-VMHost -Name 'esx02.lab.local'
        $esx03 = FakePowerCLI\Get-VMHost -Name 'esx03.lab.local'

        It 'Get-Cluster returns Lab-Cluster' {
            $clusters.Count | Should Be 1
            $clusters[0].Name | Should Be 'Lab-Cluster'
        }
        It 'Get-VMHost -Location Lab-Cluster returns 3 hosts' {
            $hosts.Count | Should Be 3
            $names = @($hosts | ForEach-Object { $_.Name })
            ($names -contains 'esx01.lab.local') | Should Be $true
            ($names -contains 'esx02.lab.local') | Should Be $true
            ($names -contains 'esx03.lab.local') | Should Be $true
        }
        It 'Get-VMHost -Location accepts a cluster object' {
            @(FakePowerCLI\Get-VMHost -Location $clusters[0]).Count | Should Be 3
        }
        It 'reports every host as Connected' {
            @($hosts | Where-Object { $_.ConnectionState -ne 'Connected' }).Count | Should Be 0
        }
        It 'computes CPU totals from cores and core speed' {
            $esx01.NumCpu | Should Be 12
            $esx01.CpuTotalMhz | Should Be 31200
            $esx03.NumCpu | Should Be 16
            $esx03.CpuTotalMhz | Should Be 41600
        }
        It 'reports CPU usage below the CPU total' {
            foreach ($h in $hosts) {
                ($h.CpuUsageMhz -gt 0) | Should Be $true
                ($h.CpuUsageMhz -lt $h.CpuTotalMhz) | Should Be $true
            }
        }
        It 'reports host memory totals' {
            $esx01.MemoryTotalGB | Should Be 64
            $esx03.MemoryTotalGB | Should Be 96
        }
        It 'computes MemoryUsageGB from powered-on VMs only (esx03: 84 GB, old-01 excluded)' {
            $esx03.MemoryUsageGB | Should Be 84
            $esx02.MemoryUsageGB | Should Be 28
            $esx01.MemoryUsageGB | Should Be 10
        }
        It 'MemoryUsageGB equals the sum of powered-on VM memory on each host' {
            foreach ($h in $hosts) {
                $sum = 0
                FakePowerCLI\Get-VM -Location $h.Name |
                    Where-Object { $_.PowerState -eq 'PoweredOn' } |
                    ForEach-Object { $sum += $_.MemoryMB }
                $h.MemoryUsageGB | Should Be ($sum / 1024)
            }
        }
        It 'Get-VM -Location on a host returns its VMs including powered-off ones' {
            $names = @(FakePowerCLI\Get-VM -Location 'esx03.lab.local' | ForEach-Object { $_.Name })
            $names.Count | Should Be 7
            ($names -contains 'old-01') | Should Be $true
        }
        It 'Get-VM -Location Lab-Cluster returns all 13 VMs' {
            @(FakePowerCLI\Get-VM -Location 'Lab-Cluster').Count | Should Be 13
        }
        It 'Get-VM -Name returns the VM with its size, power state and host' {
            $vm = FakePowerCLI\Get-VM -Name 'old-01'
            $vm.NumCpu | Should Be 2
            $vm.MemoryMB | Should Be 8192
            $vm.PowerState | Should Be 'PoweredOff'
            $vm.VMHost.Name | Should Be 'esx03.lab.local'
        }
        It 'Get-VM -Name supports wildcards' {
            $names = @(FakePowerCLI\Get-VM -Name 'web-*' | ForEach-Object { $_.Name } | Sort-Object)
            ($names -join ',') | Should Be 'web-01,web-02'
        }
        It 'Get-VM -Name for a missing VM writes an error' {
            { FakePowerCLI\Get-VM -Name 'nope-01' -ErrorAction Stop } | Should Throw 'nope-01'
            @(FakePowerCLI\Get-VM -Name 'nope-01' -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        It 'Get-VM does not return templates' {
            @(FakePowerCLI\Get-VM | Where-Object { $_.Name -like 'tpl-*' }).Count | Should Be 0
        }
        It 'Get-Template returns the two templates from the example config' {
            $names = @(FakePowerCLI\Get-Template | ForEach-Object { $_.Name } | Sort-Object)
            ($names -join ',') | Should Be 'tpl-centos65,tpl-w2k12r2'
            (FakePowerCLI\Get-Template -Name 'tpl-centos65').Name | Should Be 'tpl-centos65'
        }
        It 'Get-Datastore returns all three datastores with capacity and free space' {
            $all = @(FakePowerCLI\Get-Datastore)
            $all.Count | Should Be 3
            $sata02 = FakePowerCLI\Get-Datastore -Name 'ds-sata02'
            $sata02.CapacityGB | Should Be 1000
            $sata02.FreeSpaceGB | Should Be 150
        }
        It 'Get-Datastore -VMHost esx01.lab.local returns only ds-ssd01 and ds-sata01' {
            $names = @(FakePowerCLI\Get-Datastore -VMHost 'esx01.lab.local' | ForEach-Object { $_.Name } | Sort-Object)
            ($names -join ',') | Should Be 'ds-sata01,ds-ssd01'
        }
        It 'Get-Datastore -VMHost esx03 also returns ds-sata02' {
            @(FakePowerCLI\Get-Datastore -VMHost $esx03).Count | Should Be 3
        }
        Reset-FakeViSession
    }

    Context 'state file' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash

        $server = Connect-FakeLab
        $null = FakePowerCLI\Get-Cluster
        $null = FakePowerCLI\Get-VMHost
        $null = FakePowerCLI\Get-VM
        $null = FakePowerCLI\Get-Template
        $null = FakePowerCLI\Get-Datastore -VMHost 'esx03.lab.local'
        $null = FakePowerCLI\Disconnect-VIServer -Server $server -Confirm:$false
        $after = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash

        It 'is left unchanged by read-only calls' {
            $after | Should Be $before
        }

        Reset-FakeViSession
        $null = New-FakeViState -Mutate {
            param($state)
            ($state.vms | Where-Object { $_.name -eq 'build01' }).powerState = 'PoweredOff'
        }
        Import-Module $manifest -Force
        $null = Connect-FakeLab

        It 'is read on every call, so edits to the state show up' {
            (FakePowerCLI\Get-VMHost -Name 'esx03.lab.local').MemoryUsageGB | Should Be 76
        }

        $env:FAKEVI_STATE = Join-Path $TestDrive 'missing.json'

        It 'fails clearly when the state file is missing' {
            { FakePowerCLI\Get-VM } | Should Throw 'missing.json'
        }
        Reset-FakeViSession
    }
}
