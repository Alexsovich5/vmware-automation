$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Get-VANow.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Write-VALog.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Public/Connect-VAvCenter.ps1')

function New-ConnectTestConfig {
    param([string]$PasswordEnv = 'VA_TEST_VC_PASSWORD')
    New-Object psobject -Property @{
        vCenter = New-Object psobject -Property @{
            server      = 'vcsa.lab.local'
            user        = 'administrator@vsphere.local'
            passwordEnv = $PasswordEnv
        }
        cluster = 'Lab-Cluster'
        logDir  = (Join-Path $TestDrive 'logs')
    }
}

function New-TestCredential {
    param([string]$User, [string]$Password)
    New-Object System.Management.Automation.PSCredential($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
}

Describe 'Connect-VAvCenter' {

    $saved = $env:VA_TEST_VC_PASSWORD

    Context 'no -Credential and the password variable is not set' {
        $env:VA_TEST_VC_PASSWORD = $null
        $config = New-ConnectTestConfig
        Mock Connect-VIServer {}

        It 'throws naming the variable' {
            { Connect-VAvCenter -Config $config } | Should Throw 'VA_TEST_VC_PASSWORD'
        }
        It 'does not call Connect-VIServer' {
            Assert-MockCalled Connect-VIServer -Times 0 -Exactly
        }
    }

    Context 'the password variable is set' {
        $env:VA_TEST_VC_PASSWORD = 'from-env'
        $config = New-ConnectTestConfig
        Mock Connect-VIServer { New-Object psobject -Property @{ Name = $Server[0]; User = $Credential.UserName; IsConnected = $true } }

        $result = Connect-VAvCenter -Config $config

        It 'connects to the configured server with the configured user and the variable as password' {
            Assert-MockCalled Connect-VIServer -Times 1 -Exactly -ParameterFilter {
                $Server -contains 'vcsa.lab.local' -and
                $Credential.UserName -eq 'administrator@vsphere.local' -and
                $Credential.GetNetworkCredential().Password -ceq 'from-env'
            }
        }
        It 'returns the server object' {
            $result.Name | Should Be 'vcsa.lab.local'
        }
        It 'logs the connection without the password' {
            $log = (Get-Content (Join-Path $TestDrive 'logs/vmware-automation.log')) -join "`n"
            $log | Should Match 'vcsa.lab.local'
            $log | Should Not Match 'from-env'
        }
    }

    Context '-Credential and the password variable are both given' {
        $env:VA_TEST_VC_PASSWORD = 'from-env'
        $config = New-ConnectTestConfig
        $credential = New-TestCredential -User 'operator@vsphere.local' -Password 'from-param'
        Mock Connect-VIServer {}

        Connect-VAvCenter -Config $config -Credential $credential

        It 'uses -Credential' {
            Assert-MockCalled Connect-VIServer -Times 1 -Exactly -ParameterFilter {
                $Credential.UserName -eq 'operator@vsphere.local' -and
                $Credential.GetNetworkCredential().Password -ceq 'from-param'
            }
        }
        It 'does not use the variable' {
            Assert-MockCalled Connect-VIServer -Times 0 -Exactly -ParameterFilter {
                $Credential.GetNetworkCredential().Password -ceq 'from-env'
            }
        }
    }

    Context '-Credential without the password variable' {
        $env:VA_TEST_VC_PASSWORD = $null
        $config = New-ConnectTestConfig
        $credential = New-TestCredential -User 'operator@vsphere.local' -Password 'from-param'
        Mock Connect-VIServer {}

        Connect-VAvCenter -Config $config -Credential $credential

        It 'connects with -Credential' {
            Assert-MockCalled Connect-VIServer -Times 1 -Exactly -ParameterFilter { $Credential.UserName -eq 'operator@vsphere.local' }
        }
    }

    Context 'Connect-VIServer fails' {
        $env:VA_TEST_VC_PASSWORD = 'wrong'
        $config = New-ConnectTestConfig
        Mock Connect-VIServer { throw 'Cannot complete login due to an incorrect user name or password.' }

        It 'passes the error on' {
            { Connect-VAvCenter -Config $config } | Should Throw 'incorrect user name or password'
        }
    }

    $env:VA_TEST_VC_PASSWORD = $saved
}
