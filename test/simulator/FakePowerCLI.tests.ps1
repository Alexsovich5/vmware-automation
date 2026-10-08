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
                                'Stop-VM', 'Remove-VM', 'Move-VM', 'Get-Stat', 'Get-Snapshot', 'New-Snapshot',
                                'Remove-Snapshot', 'Get-AdvancedSetting', 'Set-AdvancedSetting', 'New-AdvancedSetting',
                                'Get-VMHostService', 'Stop-VMHostService', 'Set-VMHostService', 'Get-VMHostNtpServer')) {
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

    Context 'performance statistics' {
        Reset-FakeViSession
        $null = New-FakeViState -Mutate {
            param($state)
            # Replace the fixture's esx01 realtime CPU series with known values.
            $kept = @($state.stats | Where-Object {
                -not ($_.entity -eq 'esx01.lab.local' -and $_.stat -eq 'cpu.usage.average' -and [int]$_.intervalSecs -eq 20)
            })
            $state.stats = @($kept + (New-Object psobject -Property @{
                entity = 'esx01.lab.local'; stat = 'cpu.usage.average'; unit = '%'; intervalSecs = 20; offsetMins = 0
                values = @(41, 42, 43, 44, 45, 46, 47, 48)
            }))
        }
        Import-Module $manifest -Force
        $now = [datetime]$env:FAKEVI_NOW

        It 'throws the not-connected error before connecting' {
            { FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' } | Should Throw 'You are not currently connected to any servers'
        }

        $null = Connect-FakeLab
        $vms = @(FakePowerCLI\Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' })
        $week = @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -Start $now.AddDays(-7) -Finish $now)

        It 'has 7 days of 2-hour samples for app-idle01, newest first' {
            $week.Count | Should Be 85
            $week[0].Timestamp | Should Be $now
            $week[84].Timestamp | Should Be $now.AddMinutes(-10080)
            ($week[0].Timestamp -gt $week[1].Timestamp) | Should Be $true
        }
        It 'returns PowerCLI-shaped samples' {
            $week[0].MetricId | Should Be 'cpu.usage.average'
            $week[0].Unit | Should Be '%'
            $week[0].IntervalSecs | Should Be 7200
            $week[0].Entity.Name | Should Be 'app-idle01'
            $week[0].Instance | Should Be ''
        }
        It 'has cpu and memory history for every powered-on VM' {
            $all = @(FakePowerCLI\Get-Stat -Entity $vms -Stat 'cpu.usage.average', 'mem.usage.average' -Start $now.AddDays(-7) -Finish $now)
            $all.Count | Should Be ($vms.Count * 2 * 85)
        }
        It 'has no history for powered-off VMs' {
            @(FakePowerCLI\Get-Stat -Entity 'old-01' -Stat 'cpu.usage.average' -Start $now.AddDays(-7) -Finish $now).Count | Should Be 0
        }
        It 'limits samples to the -Start/-Finish window' {
            @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -Start $now.AddDays(-1) -Finish $now).Count | Should Be 13
            @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -Start $now.AddDays(1) -Finish $now.AddDays(2)).Count | Should Be 0
        }
        It 'filters by -Stat' {
            $mem = @(FakePowerCLI\Get-Stat -Entity 'app-busy01' -Stat 'mem.usage.average' -Start $now.AddDays(-7) -Finish $now)
            $mem.Count | Should Be 85
            @($mem | Where-Object { $_.MetricId -ne 'mem.usage.average' }).Count | Should Be 0
        }
        It 'returns the newest samples with -MaxSamples' {
            $few = @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -MaxSamples 3)
            $few.Count | Should Be 3
            $few[0].Timestamp | Should Be $now
            $few[2].Timestamp | Should Be $now.AddMinutes(-240)
        }
        It 'filters by -IntervalMins' {
            @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -IntervalMins 120 -MaxSamples 5).Count | Should Be 5
            @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -IntervalMins 5).Count | Should Be 0
        }
        It 'returns the newest 20-second samples with -Realtime' {
            $rt = @(FakePowerCLI\Get-Stat -Entity 'esx01.lab.local' -Stat 'cpu.usage.average' -Realtime -MaxSamples 3)
            $rt.Count | Should Be 3
            (@($rt | ForEach-Object { $_.Value }) -join ',') | Should Be '41,42,43'
            $rt[0].Timestamp | Should Be $now
            $rt[2].Timestamp | Should Be $now.AddSeconds(-40)
            $rt[0].IntervalSecs | Should Be 20
            $rt[0].Entity.Name | Should Be 'esx01.lab.local'
        }
        It 'keeps realtime and historical samples apart' {
            @(FakePowerCLI\Get-Stat -Entity 'esx01.lab.local' -Stat 'cpu.usage.average' -Start $now.AddDays(-7) -Finish $now).Count | Should Be 0
            @(FakePowerCLI\Get-Stat -Entity 'app-idle01' -Stat 'cpu.usage.average' -Realtime).Count | Should Be 0
        }
        It 'does not change the state file' {
            $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
            $null = FakePowerCLI\Get-Stat -Entity $vms -Stat 'cpu.usage.average' -MaxSamples 1
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        Reset-FakeViSession
    }

    Context 'snapshots' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force
        $now = [datetime]$env:FAKEVI_NOW

        It 'Get-Snapshot throws the not-connected error before connecting' {
            { FakePowerCLI\Get-Snapshot -VM 'web-01' } | Should Throw 'You are not currently connected to any servers'
        }

        $null = Connect-FakeLab
        $web01 = @(FakePowerCLI\Get-Snapshot -VM 'web-01')
        $daily1 = @($web01 | Where-Object { $_.Name -eq 'auto-daily-20140314-0200' })
        $prePatch = @($web01 | Where-Object { $_.Name -eq 'pre-patch' })

        It 'seeds web-01 with six auto-daily snapshots and one manual snapshot' {
            $web01.Count | Should Be 7
            @($web01 | Where-Object { $_.Name -like 'auto-daily-*' }).Count | Should Be 6
            $prePatch.Count | Should Be 1
        }
        It 'dates seed snapshots as day offsets from FAKEVI_NOW' {
            $daily1[0].Created | Should Be $now.AddDays(-1)
            $prePatch[0].Created | Should Be $now.AddDays(-30)
            $ages = @($web01 | Where-Object { $_.Name -like 'auto-daily-*' } | ForEach-Object { [int]($now - $_.Created).TotalDays } | Sort-Object)
            ($ages -join ',') | Should Be '1,2,4,6,8,10'
        }
        It 'returns PowerCLI-shaped snapshots' {
            $daily1[0].VM.Name | Should Be 'web-01'
            $daily1[0].VMId | Should Be 'VirtualMachine-vm-102'
            ($daily1[0].Id -like 'VirtualMachineSnapshot-snapshot-*') | Should Be $true
            $daily1[0].PSObject.TypeNames[0] | Should Be 'VMware.VimAutomation.ViCore.Impl.V1.VM.SnapshotImpl'
        }
        It 'returns nothing for a VM without snapshots' {
            @(FakePowerCLI\Get-Snapshot -VM 'web-02').Count | Should Be 0
        }
        It 'filters by -Name with wildcards' {
            @(FakePowerCLI\Get-Snapshot -VM 'web-01' -Name 'pre-*').Count | Should Be 1
        }
        It 'accepts VM objects from the pipeline' {
            @(FakePowerCLI\Get-VM -Name 'web-*' | FakePowerCLI\Get-Snapshot).Count | Should Be 7
        }

        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $null = FakePowerCLI\New-Snapshot -VM 'web-02' -Name 'x' -WhatIf
        $null = FakePowerCLI\Remove-Snapshot -Snapshot $prePatch[0] -WhatIf

        It 'New-Snapshot and Remove-Snapshot honour -WhatIf' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }

        $created = FakePowerCLI\New-Snapshot -VM 'web-02' -Name 'auto-daily-20140315-0200' -Description 'policy daily' -Quiesce

        It 'New-Snapshot stamps Created with FAKEVI_NOW and returns the snapshot' {
            $created.Name | Should Be 'auto-daily-20140315-0200'
            $created.Created | Should Be $now
            $created.Description | Should Be 'policy daily'
            $created.Quiesced | Should Be $true
            $created.VM.Name | Should Be 'web-02'
            @(FakePowerCLI\Get-Snapshot -VM 'web-02').Count | Should Be 1
        }
        It 'gives a new snapshot an id no other snapshot has' {
            @(FakePowerCLI\Get-Snapshot -VM 'web-01' | Where-Object { $_.Id -eq $created.Id }).Count | Should Be 0
        }
        It 'keeps the Created time of a new snapshot when FAKEVI_NOW moves on' {
            $saved = $env:FAKEVI_NOW
            $env:FAKEVI_NOW = '2014-03-20T02:00:00'
            $later = @(FakePowerCLI\Get-Snapshot -VM 'web-02')[0].Created
            $env:FAKEVI_NOW = $saved
            $later | Should Be $now
        }
        It 'New-Snapshot writes the not-found error for an unknown VM' {
            { FakePowerCLI\New-Snapshot -VM 'nope-01' -Name 'x' -Confirm:$false -ErrorAction Stop } | Should Throw 'nope-01'
        }

        $null = FakePowerCLI\Remove-Snapshot -Snapshot $prePatch[0] -Confirm:$false

        It 'Remove-Snapshot deletes only that snapshot' {
            $left = @(FakePowerCLI\Get-Snapshot -VM 'web-01')
            $left.Count | Should Be 6
            @($left | Where-Object { $_.Name -eq 'pre-patch' }).Count | Should Be 0
        }
        It 'Remove-Snapshot writes an error for a snapshot that is gone' {
            { FakePowerCLI\Remove-Snapshot -Snapshot $prePatch[0] -Confirm:$false -ErrorAction Stop } | Should Throw 'pre-patch'
        }
        It 'Remove-VM drops the snapshots of the removed VM' {
            $null = FakePowerCLI\Stop-VM -VM 'web-02' -Confirm:$false
            $null = FakePowerCLI\Remove-VM -VM 'web-02' -Confirm:$false
            $state = (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
            @($state.snapshots | Where-Object { $_.vm -eq 'web-02' }).Count | Should Be 0
        }
        Reset-FakeViSession
    }

    Context 'vMotion' {
        Reset-FakeViSession
        $null = New-FakeViState -Mutate {
            param($state)
            $state.stats = @(@($state.stats) + (New-Object psobject -Property @{
                entity = 'esx03.lab.local'; stat = 'mem.usage.average'; unit = '%'; intervalSecs = 7200; offsetMins = 0
                values = @(88, 87, 86, 85)
            }))
        }
        Import-Module $manifest -Force

        It 'Move-VM throws the not-connected error before connecting' {
            { FakePowerCLI\Move-VM -VM 'app03' -Destination 'esx01.lab.local' -Confirm:$false } |
                Should Throw 'You are not currently connected to any servers'
        }

        $null = Connect-FakeLab
        $now = [datetime]$env:FAKEVI_NOW
        $statsBefore = @(FakePowerCLI\Get-Stat -Entity 'esx03.lab.local' -Stat 'mem.usage.average' -Start $now.AddDays(-1) -Finish $now |
            ForEach-Object { $_.Value }) -join ','
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $null = FakePowerCLI\Move-VM -VM 'app03' -Destination 'esx01.lab.local' -WhatIf

        It 'Move-VM honours -WhatIf' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }

        $moved = FakePowerCLI\Move-VM -VM 'app03' -Destination 'esx01.lab.local' -Confirm:$false

        It 'Move-VM puts the VM on the destination host and returns it' {
            $moved.Name | Should Be 'app03'
            $moved.VMHost.Name | Should Be 'esx01.lab.local'
            (FakePowerCLI\Get-VM -Name 'app03').VMHost.Name | Should Be 'esx01.lab.local'
        }
        It 'Get-VMHost memory usage follows the VM' {
            (FakePowerCLI\Get-VMHost -Name 'esx01.lab.local').MemoryUsageGB | Should Be 18
            (FakePowerCLI\Get-VMHost -Name 'esx03.lab.local').MemoryUsageGB | Should Be 76
        }
        It 'leaves Get-Stat samples unchanged' {
            $statsBefore | Should Not BeNullOrEmpty
            (@(FakePowerCLI\Get-Stat -Entity 'esx03.lab.local' -Stat 'mem.usage.average' -Start $now.AddDays(-1) -Finish $now |
                ForEach-Object { $_.Value }) -join ',') | Should Be $statsBefore
        }
        It 'Move-VM accepts VM and host objects' {
            $vm = FakePowerCLI\Get-VM -Name 'build01'
            $target = FakePowerCLI\Get-VMHost -Name 'esx02.lab.local'
            $null = $vm | FakePowerCLI\Move-VM -Destination $target -Confirm:$false
            (FakePowerCLI\Get-VM -Name 'build01').VMHost.Name | Should Be 'esx02.lab.local'
        }
        It 'Move-VM refuses an unknown destination host' {
            { FakePowerCLI\Move-VM -VM 'app01' -Destination 'esx99.lab.local' -Confirm:$false } | Should Throw 'esx99.lab.local'
            (FakePowerCLI\Get-VM -Name 'app01').VMHost.Name | Should Be 'esx03.lab.local'
        }
        It 'Move-VM writes the not-found error for an unknown VM' {
            { FakePowerCLI\Move-VM -VM 'nope-01' -Destination 'esx01.lab.local' -Confirm:$false -ErrorAction Stop } | Should Throw 'nope-01'
        }
        Reset-FakeViSession
    }

    Context 'hardening cmdlets' {
        Reset-FakeViSession
        $null = New-FakeViState
        Import-Module $manifest -Force

        It 'Get-AdvancedSetting throws the not-connected error before connecting' {
            { FakePowerCLI\Get-AdvancedSetting -Entity 'dc01' } | Should Throw 'You are not currently connected to any servers'
        }
        It 'Get-VMHostService throws the not-connected error before connecting' {
            { FakePowerCLI\Get-VMHostService -VMHost 'esx01.lab.local' } | Should Throw 'You are not currently connected to any servers'
        }

        $null = Connect-FakeLab

        It 'Get-AdvancedSetting returns host settings with their value and entity' {
            $s = @(FakePowerCLI\Get-AdvancedSetting -Entity 'esx02.lab.local' -Name 'UserVars.ESXiShellTimeOut')
            $s.Count | Should Be 1
            $s[0].Name | Should Be 'UserVars.ESXiShellTimeOut'
            "$($s[0].Value)" | Should Be '900'
            $s[0].Entity.Name | Should Be 'esx02.lab.local'
            $s[0].Type | Should Be 'VMHost'
        }
        It 'Get-AdvancedSetting accepts VM objects and wildcard names' {
            $vm = FakePowerCLI\Get-VM -Name 'dc01'
            $s = @(FakePowerCLI\Get-AdvancedSetting -Entity $vm -Name 'isolation.tools.*')
            $s.Count | Should Be 4
            $s[0].Type | Should Be 'VM'
        }
        It 'Get-AdvancedSetting returns nothing for a setting a VM does not have' {
            @(FakePowerCLI\Get-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable').Count | Should Be 0
        }
        It 'Get-VMHostService reports SSH running on esx02.lab.local only' {
            $ssh = @(FakePowerCLI\Get-VMHostService -VMHost 'esx02.lab.local' | Where-Object { $_.Key -eq 'TSM-SSH' })
            $ssh.Count | Should Be 1
            $ssh[0].Running | Should Be $true
            $ssh[0].Policy | Should Be 'on'
            $ssh[0].VMHost.Name | Should Be 'esx02.lab.local'
            (@(FakePowerCLI\Get-VMHostService -VMHost 'esx01.lab.local' | Where-Object { $_.Key -eq 'TSM-SSH' })[0].Running) | Should Be $false
        }
        It 'Get-VMHostNtpServer lists servers, and none for esx03.lab.local' {
            (@(FakePowerCLI\Get-VMHostNtpServer -VMHost 'esx01.lab.local').Count -gt 0) | Should Be $true
            @(FakePowerCLI\Get-VMHostNtpServer -VMHost 'esx03.lab.local').Count | Should Be 0
        }

        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $setting = FakePowerCLI\Get-AdvancedSetting -Entity 'web-01' -Name 'RemoteDisplay.maxConnections'
        $null = FakePowerCLI\Set-AdvancedSetting -AdvancedSetting $setting -Value '1' -WhatIf
        $null = FakePowerCLI\New-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable' -Value 'TRUE' -WhatIf
        $service = @(FakePowerCLI\Get-VMHostService -VMHost 'esx02.lab.local' | Where-Object { $_.Key -eq 'TSM-SSH' })
        $null = FakePowerCLI\Stop-VMHostService -HostService $service -WhatIf
        $null = FakePowerCLI\Set-VMHostService -HostService $service -Policy 'Off' -WhatIf

        It 'the mutating cmdlets honour -WhatIf' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }

        $updated = FakePowerCLI\Set-AdvancedSetting -AdvancedSetting $setting -Value '1' -Confirm:$false

        It 'Set-AdvancedSetting changes and returns the setting' {
            "$($updated.Value)" | Should Be '1'
            "$((FakePowerCLI\Get-AdvancedSetting -Entity 'web-01' -Name 'RemoteDisplay.maxConnections').Value)" | Should Be '1'
        }

        $created = FakePowerCLI\New-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable' -Value 'TRUE' -Confirm:$false

        It 'New-AdvancedSetting adds a setting to the VM' {
            $created.Name | Should Be 'isolation.tools.copy.disable'
            (FakePowerCLI\Get-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable').Value | Should Be 'TRUE'
        }
        It 'New-AdvancedSetting refuses an existing setting without -Force and replaces it with -Force' {
            { FakePowerCLI\New-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable' -Value 'FALSE' -Confirm:$false } |
                Should Throw 'already exists'
            $null = FakePowerCLI\New-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable' -Value 'FALSE' -Force -Confirm:$false
            @(FakePowerCLI\Get-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable').Count | Should Be 1
            (FakePowerCLI\Get-AdvancedSetting -Entity 'web-02' -Name 'isolation.tools.copy.disable').Value | Should Be 'FALSE'
        }

        $stopped = FakePowerCLI\Stop-VMHostService -HostService $service -Confirm:$false
        $policy = FakePowerCLI\Set-VMHostService -HostService $service -Policy 'Off' -Confirm:$false

        It 'Stop-VMHostService stops the service and Set-VMHostService changes its policy' {
            $stopped.Running | Should Be $false
            $policy.Policy | Should Be 'off'
            $now = @(FakePowerCLI\Get-VMHostService -VMHost 'esx02.lab.local' | Where-Object { $_.Key -eq 'TSM-SSH' })[0]
            $now.Running | Should Be $false
            $now.Policy | Should Be 'off'
        }
        It 'leaves the other services of the host alone' {
            $ntpd = @(FakePowerCLI\Get-VMHostService -VMHost 'esx02.lab.local' | Where-Object { $_.Key -eq 'ntpd' })
            $ntpd.Count | Should Be 1
            $ntpd[0].Running | Should Be $true
            $ntpd[0].Policy | Should Be 'on'
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
