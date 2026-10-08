$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Resolve-VAExactEntity.ps1')

function New-TestVM {
    param([string]$Name, [string]$Id = '')
    New-Object psobject -Property @{ Name = $Name; Id = $Id }
}

Describe 'Resolve-VAExactEntity' {

    Context 'names with wildcard characters' {
        Mock Get-VM { New-TestVM 'dc01' }
        Mock Get-VMHost { New-TestVM 'esx01.lab.local' }

        It 'rejects *' {
            { Resolve-VAExactEntity -EntityType VM -Name 'dc0*' } | Should Throw 'wildcard'
        }
        It 'rejects ?' {
            { Resolve-VAExactEntity -EntityType VM -Name 'dc0?' } | Should Throw 'wildcard'
        }
        It 'rejects [ ]' {
            { Resolve-VAExactEntity -EntityType VM -Name 'dc0[1]' } | Should Throw 'wildcard'
        }
        It 'rejects the wildcard escape character' {
            { Resolve-VAExactEntity -EntityType VM -Name 'dc0`1' } | Should Throw 'wildcard'
        }
        It 'rejects a wildcard host name' {
            { Resolve-VAExactEntity -EntityType VMHost -Name 'esx*' } | Should Throw 'wildcard'
        }
        It 'never asks vCenter' {
            Assert-MockCalled Get-VM -Times 0 -Exactly
            Assert-MockCalled Get-VMHost -Times 0 -Exactly
        }
    }

    Context 'an empty name' {
        Mock Get-VM { New-TestVM 'dc01' }

        It 'is rejected without a lookup' {
            { Resolve-VAExactEntity -EntityType VM -Name '  ' } | Should Throw 'No VirtualMachine name'
            Assert-MockCalled Get-VM -Times 0 -Exactly
        }
    }

    Context 'a lookup that returns more than the exact name' {
        Mock Get-VM { New-TestVM 'web-01' 'vm-1'; New-TestVM 'web-010' 'vm-2' }

        $vm = Resolve-VAExactEntity -EntityType VM -Name 'web-01'

        It 'returns only the VM whose name equals the request' {
            @($vm).Count | Should Be 1
            $vm.Id | Should Be 'vm-1'
        }
        It 'looks the name up once' {
            Assert-MockCalled Get-VM -Times 1 -Exactly -ParameterFilter { @($Name)[0] -eq 'web-01' }
        }
    }

    Context 'a name that differs only in case' {
        Mock Get-VM { New-TestVM 'DC01' }

        It 'resolves to the inventory object, whose Name is the inventory spelling' {
            (Resolve-VAExactEntity -EntityType VM -Name 'dc01').Name | Should Be 'DC01'
        }
    }

    Context 'two VMs with the same name' {
        Mock Get-VM { New-TestVM 'web-01' 'vm-1'; New-TestVM 'web-01' 'vm-2' }

        It 'throws instead of picking one' {
            { Resolve-VAExactEntity -EntityType VM -Name 'web-01' } | Should Throw 'ambiguous'
        }
    }

    Context 'no match' {
        Mock Get-VM { New-TestVM 'web-010' }

        It 'throws a not-found error' {
            { Resolve-VAExactEntity -EntityType VM -Name 'web-01' } | Should Throw "Could not find VirtualMachine with name 'web-01'"
        }
    }

    Context 'a lookup error' {
        Mock Get-VM { throw "Could not find VirtualMachine with name 'nope-01'." }

        It 'is passed on' {
            { Resolve-VAExactEntity -EntityType VM -Name 'nope-01' } | Should Throw 'nope-01'
        }
    }

    Context 'a host' {
        Mock Get-VM { New-TestVM 'esx01.lab.local' }
        Mock Get-VMHost { New-TestVM 'esx01.lab.local' 'host-10'; New-TestVM 'esx01.lab.local.old' 'host-11' }

        $vmHost = Resolve-VAExactEntity -EntityType VMHost -Name 'esx01.lab.local'

        It 'is looked up with Get-VMHost and matched exactly' {
            $vmHost.Id | Should Be 'host-10'
            Assert-MockCalled Get-VMHost -Times 1 -Exactly
            Assert-MockCalled Get-VM -Times 0 -Exactly
        }
    }
}
