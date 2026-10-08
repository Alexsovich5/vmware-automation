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
                                'Get-VM', 'Get-Template', 'Get-Datastore', 'New-VM', 'Set-VM', 'Start-VM',
                                'Stop-VM', 'Remove-VM')) {
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

    Context 'provisioning cmdlets' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force
        $null = Connect-FakeLab

        $created = FakePowerCLI\New-VM -Name 'web-03' -Template 'tpl-centos65' -VMHost 'esx01.lab.local' -Datastore 'ds-sata01'

        It 'New-VM clones a powered-off VM sized like the template' {
            $created.Name | Should Be 'web-03'
            $created.PowerState | Should Be 'PoweredOff'
            $created.NumCpu | Should Be 1
            $created.MemoryMB | Should Be 1024
            $created.ProvisionedSpaceGB | Should Be 16
            $created.VMHost.Name | Should Be 'esx01.lab.local'
        }
        It 'New-VM gives the VM a new id' {
            $ids = @(FakePowerCLI\Get-VM | ForEach-Object { $_.Id })
            @($ids | Where-Object { $_ -eq $created.Id }).Count | Should Be 1
        }
        It 'New-VM takes the template disk from the datastore free space' {
            (FakePowerCLI\Get-Datastore -Name 'ds-sata01').FreeSpaceGB | Should Be 684
        }
        It 'New-VM keeps the VM after the call (state is saved)' {
            (FakePowerCLI\Get-VM -Name 'web-03').VMHost.Name | Should Be 'esx01.lab.local'
        }
        It 'New-VM refuses a duplicate name' {
            { FakePowerCLI\New-VM -Name 'web-03' -Template 'tpl-centos65' -VMHost 'esx01.lab.local' -Datastore 'ds-sata01' } |
                Should Throw 'already exists'
        }
        It 'New-VM refuses an unknown template' {
            { FakePowerCLI\New-VM -Name 'web-09' -Template 'tpl-none' -VMHost 'esx01.lab.local' -Datastore 'ds-sata01' } |
                Should Throw 'tpl-none'
        }
        It 'New-VM refuses a datastore the host does not mount' {
            { FakePowerCLI\New-VM -Name 'web-09' -Template 'tpl-centos65' -VMHost 'esx01.lab.local' -Datastore 'ds-sata02' } |
                Should Throw 'ds-sata02'
        }

        $sized = FakePowerCLI\Set-VM -VM $created -NumCpu 2 -MemoryMB 4096 -Notes 'frontend' -Confirm:$false

        It 'Set-VM changes vCPU, memory and notes' {
            $sized.NumCpu | Should Be 2
            $sized.MemoryMB | Should Be 4096
            $sized.Notes | Should Be 'frontend'
            (FakePowerCLI\Get-VM -Name 'web-03').MemoryMB | Should Be 4096
        }
        It 'a powered-off VM does not count towards host memory' {
            (FakePowerCLI\Get-VMHost -Name 'esx01.lab.local').MemoryUsageGB | Should Be 10
        }

        $started = FakePowerCLI\Start-VM -VM 'web-03'

        It 'Start-VM powers the VM on and returns it' {
            $started.Name | Should Be 'web-03'
            $started.PowerState | Should Be 'PoweredOn'
            (FakePowerCLI\Get-VM -Name 'web-03').PowerState | Should Be 'PoweredOn'
        }
        It 'a powered-on VM counts towards host memory' {
            (FakePowerCLI\Get-VMHost -Name 'esx01.lab.local').MemoryUsageGB | Should Be 14
        }

        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $null = FakePowerCLI\New-VM -Name 'web-05' -Template 'tpl-centos65' -VMHost 'esx01.lab.local' -Datastore 'ds-sata01' -WhatIf
        $null = FakePowerCLI\Set-VM -VM 'web-03' -NumCpu 4 -WhatIf
        $null = FakePowerCLI\Start-VM -VM 'old-01' -WhatIf

        It 'the provisioning cmdlets honour -WhatIf' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        Reset-FakeViSession
    }

    Context 'deprovisioning cmdlets' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force
        $null = Connect-FakeLab

        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $null = FakePowerCLI\Stop-VM -VM 'test-01' -WhatIf
        $null = FakePowerCLI\Remove-VM -VM 'old-01' -DeletePermanently -WhatIf

        It 'Stop-VM and Remove-VM honour -WhatIf' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        It 'Remove-VM refuses a powered-on VM' {
            { FakePowerCLI\Remove-VM -VM 'test-01' -DeletePermanently -Confirm:$false } |
                Should Throw 'cannot be performed in the current state (Powered on)'
            @(FakePowerCLI\Get-VM -Name 'test-01').Count | Should Be 1
        }

        $stopped = FakePowerCLI\Stop-VM -VM 'test-01' -Confirm:$false

        It 'Stop-VM powers the VM off and returns it' {
            $stopped.Name | Should Be 'test-01'
            $stopped.PowerState | Should Be 'PoweredOff'
            (FakePowerCLI\Get-VM -Name 'test-01').PowerState | Should Be 'PoweredOff'
        }
        It 'a stopped VM no longer counts towards host memory' {
            (FakePowerCLI\Get-VMHost -Name 'esx01.lab.local').MemoryUsageGB | Should Be 8
        }

        $null = FakePowerCLI\Remove-VM -VM $stopped -DeletePermanently -Confirm:$false

        It 'Remove-VM takes the VM out of the inventory' {
            @(FakePowerCLI\Get-VM -Name 'test-*').Count | Should Be 0
        }
        It 'Remove-VM -DeletePermanently gives the disk space back to the datastore' {
            (FakePowerCLI\Get-Datastore -Name 'ds-sata01').FreeSpaceGB | Should Be 716
        }

        $null = FakePowerCLI\Remove-VM -VM 'old-01' -Confirm:$false

        It 'Remove-VM without -DeletePermanently only unregisters the VM' {
            @(FakePowerCLI\Get-VM -Name 'old-*').Count | Should Be 0
            (FakePowerCLI\Get-Datastore -Name 'ds-sata02').FreeSpaceGB | Should Be 150
        }
        It 'Remove-VM writes the not-found error for an unknown VM' {
            { FakePowerCLI\Remove-VM -VM 'nope-01' -Confirm:$false -ErrorAction Stop } | Should Throw 'nope-01'
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
