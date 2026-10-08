$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Import-VAPowerCLI.ps1')

$fakeModule = Join-Path $repo 'simulator/FakePowerCLI/FakePowerCLI.psd1'

Describe 'Import-VAPowerCLI' {

    $savedModule = $env:VA_POWERCLI_MODULE

    Context 'the snap-in is registered' {
        $env:VA_POWERCLI_MODULE = $fakeModule
        Mock Get-PSSnapin { New-Object psobject -Property @{ Name = 'VMware.VimAutomation.Core'; Version = '5.5' } }
        Mock Add-PSSnapin {}
        Mock Import-Module {}

        Import-VAPowerCLI

        It 'asks for the registered PowerCLI snap-in' {
            Assert-MockCalled Get-PSSnapin -Times 1 -ParameterFilter { $Registered -and $Name -contains 'VMware.VimAutomation.Core' }
        }
        It 'adds the snap-in once' {
            Assert-MockCalled Add-PSSnapin -Times 1 -Exactly -ParameterFilter { $Name -contains 'VMware.VimAutomation.Core' }
        }
        It 'does not import the module override' {
            Assert-MockCalled Import-Module -Times 0 -Exactly
        }
    }

    Context 'the snap-in is not registered' {
        $env:VA_POWERCLI_MODULE = $fakeModule
        Mock Get-PSSnapin {}
        Mock Add-PSSnapin {}
        Mock Import-Module {}

        Import-VAPowerCLI

        It 'does not add the snap-in' {
            Assert-MockCalled Add-PSSnapin -Times 0 -Exactly
        }
        It 'imports the module named by VA_POWERCLI_MODULE' {
            Assert-MockCalled Import-Module -Times 1 -Exactly -ParameterFilter { $Name -contains $fakeModule }
        }
    }

    Context 'neither the snap-in nor the module override is available' {
        $env:VA_POWERCLI_MODULE = $null
        Mock Get-PSSnapin {}
        Mock Add-PSSnapin {}
        Mock Import-Module {}

        It 'throws a clear error' {
            { Import-VAPowerCLI } | Should Throw 'VMware.VimAutomation.Core'
        }
        It 'imports nothing' {
            Assert-MockCalled Add-PSSnapin -Times 0 -Exactly
            Assert-MockCalled Import-Module -Times 0 -Exactly
        }
    }

    Context 'the module override points at a missing file' {
        $env:VA_POWERCLI_MODULE = Join-Path $TestDrive 'missing/PowerCLI.psd1'
        Mock Get-PSSnapin {}
        Mock Import-Module {}

        It 'throws naming the path' {
            { Import-VAPowerCLI } | Should Throw 'missing/PowerCLI.psd1'
        }
        It 'does not try to import it' {
            Assert-MockCalled Import-Module -Times 0 -Exactly
        }
    }

    $env:VA_POWERCLI_MODULE = $savedModule
}
