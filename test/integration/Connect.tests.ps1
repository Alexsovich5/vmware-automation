$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$helper = Join-Path $repo 'config/Connect-vCenter.ps1'

function Reset-ConnectSession {
    Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

Describe 'config/Connect-vCenter.ps1' {

    Context 'against FakePowerCLI with the password in the environment' {
        Reset-ConnectSession
        $configPath = New-FakeViState
        $result = & $helper -ConfigPath $configPath

        It 'connects and sets DefaultVIServer' {
            $global:DefaultVIServer.Name | Should Be 'vcsa.lab.local'
            $global:DefaultVIServer.IsConnected | Should Be $true
        }
        It 'returns the server object' {
            $result.Name | Should Be 'vcsa.lab.local'
        }
        It 'loads FakePowerCLI through VA_POWERCLI_MODULE' {
            (Get-Module FakePowerCLI) | Should Not BeNullOrEmpty
        }
        It 'leaves the session usable for inventory calls' {
            @(Get-VMHost -Location 'Lab-Cluster').Count | Should Be 3
        }
        It 'writes the connection to the log in the test drive' {
            (Join-Path $TestDrive 'logs/vmware-automation.log') | Should Contain 'vcsa.lab.local'
        }
        Reset-ConnectSession
    }

    Context 'with a wrong password in the environment' {
        Reset-ConnectSession
        $configPath = New-FakeViState
        $env:VA_VCENTER_PASSWORD = 'not-the-password'

        It 'throws the login error' {
            { & $helper -ConfigPath $configPath } | Should Throw 'incorrect user name or password'
        }
        It 'leaves DefaultVIServer unset' {
            $global:DefaultVIServer | Should BeNullOrEmpty
        }
        Reset-ConnectSession
    }

    Context 'with -Credential and no password variable' {
        Reset-ConnectSession
        $configPath = New-FakeViState
        $env:VA_VCENTER_PASSWORD = $null
        $credential = New-Object System.Management.Automation.PSCredential('administrator@vsphere.local',
            (ConvertTo-SecureString 'VMware1!' -AsPlainText -Force))
        $result = & $helper -ConfigPath $configPath -Credential $credential

        It 'connects without prompting' {
            $result.Name | Should Be 'vcsa.lab.local'
            $global:DefaultVIServer.Name | Should Be 'vcsa.lab.local'
        }
        Reset-ConnectSession
    }
}
