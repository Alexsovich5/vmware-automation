$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '..'))
. (Join-Path $here 'TestHelpers.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Read-VAConfig.ps1')

$fixturePath = Join-Path $repo 'simulator/fixtures/lab-inventory.json'

Describe 'New-FakeViState' {

    Context 'default call' {
        $configPath = New-FakeViState
        $root = [System.IO.Path]::GetFullPath($TestDrive)

        It 'returns the config copied into the config folder of the test drive' {
            $configPath | Should Be (Join-Path $TestDrive 'config/settings.example.json')
            $configPath | Should Exist
        }
        It 'resolves outputDir and logDir inside the test drive' {
            $config = Read-VAConfig -Path $configPath
            $config.outputDir.StartsWith($root) | Should Be $true
            $config.logDir.StartsWith($root) | Should Be $true
            $config.outputDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'out')))
            $config.logDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'logs')))
        }
        It 'points FAKEVI_STATE at a copy of the fixture in the test drive' {
            $env:FAKEVI_STATE.StartsWith($root) | Should Be $true
            $env:FAKEVI_STATE | Should Exist
            ((Get-Content $env:FAKEVI_STATE) -join "`n") | Should Be ((Get-Content $fixturePath) -join "`n")
        }
        It 'sets the simulated clock' {
            $env:FAKEVI_NOW | Should Be '2014-03-15T02:00:00'
        }
        It 'points VA_POWERCLI_MODULE at the FakePowerCLI manifest' {
            $env:VA_POWERCLI_MODULE | Should Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'simulator/FakePowerCLI/FakePowerCLI.psd1')))
            $env:VA_POWERCLI_MODULE | Should Exist
        }
        It 'sets the vCenter password variable' {
            $env:VA_VCENTER_PASSWORD | Should Be 'VMware1!'
        }
    }

    Context 'with -Mutate' {
        $null = New-FakeViState -Mutate {
            param($state)
            $state.vms = @($state.vms | Where-Object { $_.name -ne 'old-01' })
        }
        $state = (Get-Content $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
        $fixture = (Get-Content $fixturePath) -join "`n" | ConvertFrom-Json

        It 'applies the change to the copied state' {
            (@($state.vms | ForEach-Object { $_.name }) -contains 'old-01') | Should Be $false
            @($state.vms).Count | Should Be (@($fixture.vms).Count - 1)
        }
        It 'keeps the rest of the state' {
            @($state.hosts).Count | Should Be 3
            $state.vCenter.server | Should Be 'vcsa.lab.local'
        }
        It 'leaves the fixture itself untouched' {
            (@($fixture.vms | ForEach-Object { $_.name }) -contains 'old-01') | Should Be $true
        }
    }
}
