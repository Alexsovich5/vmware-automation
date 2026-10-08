$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Test-VAVMRequest.ps1')
. (Join-Path $src 'Private/Select-VAPlacementHost.ps1')
. (Join-Path $src 'Private/Select-VADatastore.ps1')
. (Join-Path $src 'Public/New-VAVirtualMachine.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

# The fixture's hosts and the datastores mounted on all of them.
function Set-PlacementMocks {
    Mock Get-VM {}
    Mock Get-VMHost {
        New-Object psobject -Property @{ Name = 'esx01.lab.local'; ConnectionState = 'Connected'; MemoryUsageGB = 10; MemoryTotalGB = 64 }
        New-Object psobject -Property @{ Name = 'esx02.lab.local'; ConnectionState = 'Connected'; MemoryUsageGB = 28; MemoryTotalGB = 64 }
        New-Object psobject -Property @{ Name = 'esx03.lab.local'; ConnectionState = 'Connected'; MemoryUsageGB = 84; MemoryTotalGB = 96 }
    }
    Mock Get-Datastore {
        New-Object psobject -Property @{ Name = 'ds-ssd01'; CapacityGB = 500; FreeSpaceGB = 180 }
        New-Object psobject -Property @{ Name = 'ds-sata01'; CapacityGB = 2000; FreeSpaceGB = 700 }
    }
}

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

Describe 'New-VAVirtualMachine' {

    Context 'a valid request' {
        $config = Get-TestConfig
        Set-PlacementMocks
        Mock New-VM { New-Object psobject -Property @{ Name = $Name; PowerState = 'PoweredOff' } }
        Mock Set-VM { New-Object psobject -Property @{ Name = 'web-03'; PowerState = 'PoweredOff'; NumCpu = $NumCpu; MemoryMB = $MemoryMB } }
        Mock Start-VM { New-Object psobject -Property @{ Name = 'web-03'; PowerState = 'PoweredOn'; NumCpu = 2; MemoryMB = 4096 } }

        $result = New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 -Notes 'frontend'

        It 'clones the template onto the least loaded host and the datastore with most free space' {
            Assert-MockCalled New-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'web-03' -and
                (@($Template) | ForEach-Object { "$_" }) -contains 'tpl-centos65' -and
                $VMHost.Name -eq 'esx01.lab.local' -and
                $Datastore.Name -eq 'ds-sata01'
            }
        }
        It 'sets vCPU, memory and notes without prompting' {
            Assert-MockCalled Set-VM -Times 1 -Exactly -ParameterFilter {
                $NumCpu -eq 2 -and $MemoryMB -eq 4096 -and $Notes -eq 'frontend' -and
                $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'powers the VM on' {
            Assert-MockCalled Start-VM -Times 1 -Exactly
        }
        It 'returns the powered-on VM' {
            $result.Name | Should Be 'web-03'
            $result.PowerState | Should Be 'PoweredOn'
        }
        It 'logs the placement' {
            $log = Join-Path $TestDrive 'logs/vmware-automation.log'
            $log | Should Contain 'web-03'
            $log | Should Contain 'esx01.lab.local'
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Set-PlacementMocks
        Mock New-VM {}
        Mock Set-VM {}
        Mock Start-VM {}

        $result = New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 -WhatIf

        It 'never calls New-VM' {
            Assert-MockCalled New-VM -Times 0 -Exactly
        }
        It 'never calls Set-VM or Start-VM' {
            Assert-MockCalled Set-VM -Times 0 -Exactly
            Assert-MockCalled Start-VM -Times 0 -Exactly
        }
        It 'returns nothing' {
            $result | Should BeNullOrEmpty
        }
        It 'still validates and places the request' {
            Assert-MockCalled Get-VMHost -Times 1 -Exactly
        }
    }

    Context 'an invalid request' {
        $config = Get-TestConfig
        Set-PlacementMocks
        Mock New-VM {}

        It 'throws the validation message' {
            { New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4097 } |
                Should Throw 'not a multiple of 4'
        }
        It 'does not look for a host or clone anything' {
            Assert-MockCalled Get-VMHost -Times 0 -Exactly
            Assert-MockCalled New-VM -Times 0 -Exactly
        }
    }

    Context 'an explicit datastore' {
        $config = Get-TestConfig
        Set-PlacementMocks
        Mock New-VM { New-Object psobject -Property @{ Name = $Name } }
        Mock Set-VM { New-Object psobject -Property @{ Name = 'web-03' } }
        Mock Start-VM { New-Object psobject -Property @{ Name = 'web-03'; PowerState = 'PoweredOn' } }

        $null = New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 1 -MemoryMB 1024 -Datastore 'ds-ssd01'

        It 'clones onto that datastore' {
            Assert-MockCalled New-VM -Times 1 -Exactly -ParameterFilter { $Datastore.Name -eq 'ds-ssd01' }
        }
    }

    Context 'New-VM fails' {
        $config = Get-TestConfig
        Set-PlacementMocks
        Mock New-VM { throw 'Insufficient disk space on datastore' }
        Mock Set-VM {}
        Mock Start-VM {}

        It 'passes the error on' {
            { New-VAVirtualMachine -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 } |
                Should Throw 'Insufficient disk space'
        }
        It 'does not size or power on anything' {
            Assert-MockCalled Set-VM -Times 0 -Exactly
            Assert-MockCalled Start-VM -Times 0 -Exactly
        }
    }
}
