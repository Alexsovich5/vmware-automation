$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Resolve-VAExactEntity.ps1')
. (Join-Path $src 'Public/Remove-VAVirtualMachine.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

Describe 'Remove-VAVirtualMachine' {

    Context 'the command' {
        $command = Get-Command Remove-VAVirtualMachine
        $binding = $command.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        It 'supports -WhatIf and -Confirm' {
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
        It 'declares a high confirm impact' {
            "$($binding.ConfirmImpact)" | Should Be 'High'
        }
    }

    Context 'a protected VM' {
        $config = Get-TestConfig
        Mock Get-VM { New-Object psobject -Property @{ Name = 'vcsa'; PowerState = 'PoweredOn' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        It 'throws naming the VM as protected' {
            { Remove-VAVirtualMachine -Config $config -Name 'vcsa' -Confirm:$false } | Should Throw "VM 'vcsa' is protected"
        }
        It 'matches the protected list without regard to case' {
            { Remove-VAVirtualMachine -Config $config -Name 'DC01' -Confirm:$false } | Should Throw 'is protected'
        }
        It 'never calls Remove-VM or Stop-VM' {
            Assert-MockCalled Remove-VM -Times 0 -Exactly
            Assert-MockCalled Stop-VM -Times 0 -Exactly
        }
        It 'logs the refusal' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'protected'
        }
    }

    Context 'a powered-on VM' {
        $config = Get-TestConfig
        $global:VARemoveOrder = @()
        Mock Get-VM { New-Object psobject -Property @{ Name = 'test-01'; PowerState = 'PoweredOn' } }
        Mock Stop-VM { $global:VARemoveOrder += 'Stop-VM'; New-Object psobject -Property @{ Name = 'test-01'; PowerState = 'PoweredOff' } }
        Mock Remove-VM { $global:VARemoveOrder += 'Remove-VM' }

        Remove-VAVirtualMachine -Config $config -Name 'test-01' -Confirm:$false

        It 'stops the VM without prompting' {
            Assert-MockCalled Stop-VM -Times 1 -Exactly -ParameterFilter {
                (@($VM) | ForEach-Object { $_.Name }) -contains 'test-01' -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'deletes it permanently without prompting' {
            Assert-MockCalled Remove-VM -Times 1 -Exactly -ParameterFilter {
                $DeletePermanently -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'stops it before removing it' {
            ($global:VARemoveOrder -join ',') | Should Be 'Stop-VM,Remove-VM'
        }
        It 'logs the removal' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'Removed test-01'
        }
    }

    Context 'a powered-off VM' {
        $config = Get-TestConfig
        Mock Get-VM { New-Object psobject -Property @{ Name = 'old-01'; PowerState = 'PoweredOff' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        Remove-VAVirtualMachine -Config $config -Name 'old-01' -Confirm:$false

        It 'does not call Stop-VM' {
            Assert-MockCalled Stop-VM -Times 0 -Exactly
        }
        It 'removes it permanently' {
            Assert-MockCalled Remove-VM -Times 1 -Exactly -ParameterFilter { $DeletePermanently }
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Mock Get-VM { New-Object psobject -Property @{ Name = 'test-01'; PowerState = 'PoweredOn' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        $result = Remove-VAVirtualMachine -Config $config -Name 'test-01' -WhatIf

        It 'never calls Stop-VM' {
            Assert-MockCalled Stop-VM -Times 0 -Exactly
        }
        It 'never calls Remove-VM' {
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
        It 'returns nothing' {
            $result | Should BeNullOrEmpty
        }
        It 'still looks the VM up' {
            Assert-MockCalled Get-VM -Times 1 -Exactly
        }
    }

    Context 'a wildcard name that would match a protected VM' {
        $config = Get-TestConfig
        Mock Get-VM { New-Object psobject -Property @{ Name = 'dc01'; PowerState = 'PoweredOff' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        It 'is rejected' {
            { Remove-VAVirtualMachine -Config $config -Name 'dc0*' -Confirm:$false } | Should Throw 'wildcard'
        }
        It 'never looks anything up, stops or removes' {
            Assert-MockCalled Get-VM -Times 0 -Exactly
            Assert-MockCalled Stop-VM -Times 0 -Exactly
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
    }

    Context 'two VMs with the same name' {
        $config = Get-TestConfig
        Mock Get-VM {
            New-Object psobject -Property @{ Name = 'web-01'; Id = 'vm-1'; PowerState = 'PoweredOff' }
            New-Object psobject -Property @{ Name = 'web-01'; Id = 'vm-2'; PowerState = 'PoweredOff' }
        }
        Mock Stop-VM {}
        Mock Remove-VM {}

        It 'throws instead of deleting either' {
            { Remove-VAVirtualMachine -Config $config -Name 'web-01' -Confirm:$false } | Should Throw 'ambiguous'
        }
        It 'removes nothing' {
            Assert-MockCalled Stop-VM -Times 0 -Exactly
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
    }

    Context 'a lookup that also returns a similarly named VM' {
        $config = Get-TestConfig
        Mock Get-VM {
            New-Object psobject -Property @{ Name = 'web-010'; Id = 'vm-2'; PowerState = 'PoweredOff' }
            New-Object psobject -Property @{ Name = 'web-01'; Id = 'vm-1'; PowerState = 'PoweredOff' }
        }
        Mock Remove-VM {}

        Remove-VAVirtualMachine -Config $config -Name 'web-01' -Confirm:$false

        It 'removes only the VM with exactly that name, once' {
            Assert-MockCalled Remove-VM -Times 1 -Exactly
            Assert-MockCalled Remove-VM -Times 1 -Exactly -ParameterFilter { @($VM)[0].Id -eq 'vm-1' }
        }
    }

    Context 'a protected VM listed in a different case than the inventory' {
        $config = Get-TestConfig
        $config.provisioning.protectedVMs = @('Build01')
        Mock Get-VM { New-Object psobject -Property @{ Name = 'BUILD01'; PowerState = 'PoweredOn' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        It 'is refused' {
            { Remove-VAVirtualMachine -Config $config -Name 'build01' -Confirm:$false } | Should Throw 'is protected'
        }
        It 'never stops or removes it' {
            Assert-MockCalled Stop-VM -Times 0 -Exactly
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
    }

    Context 'a protected VM given by its exact name' {
        $config = Get-TestConfig
        Mock Get-VM { New-Object psobject -Property @{ Name = 'dc01'; PowerState = 'PoweredOn' } }
        Mock Stop-VM {}
        Mock Remove-VM {}

        It 'is refused' {
            { Remove-VAVirtualMachine -Config $config -Name 'dc01' -Confirm:$false } | Should Throw "VM 'dc01' is protected"
        }
        It 'never stops or removes it' {
            Assert-MockCalled Stop-VM -Times 0 -Exactly
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
    }

    Context 'a VM that does not exist' {
        $config = Get-TestConfig
        Mock Get-VM { throw "Could not find VirtualMachine with name 'nope-01'." }
        Mock Remove-VM {}

        It 'throws the lookup error' {
            { Remove-VAVirtualMachine -Config $config -Name 'nope-01' -Confirm:$false } | Should Throw 'nope-01'
        }
        It 'never calls Remove-VM' {
            Assert-MockCalled Remove-VM -Times 0 -Exactly
        }
    }
}
