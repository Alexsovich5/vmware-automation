$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$manifestPath = Join-Path $repo 'src/VMwareAutomation/VMwareAutomation.psd1'

function Reset-HardeningSession {
    Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

function Connect-HardeningLab {
    param([string]$ConfigPath)
    $module = Import-Module $manifestPath -Global -Force -PassThru
    $config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
    & $module { Import-VAPowerCLI }
    $null = Connect-VAvCenter -Config $config
    $config
}

function Get-NonCompliantKey {
    param([object[]]$Rows)
    @($Rows | Where-Object { -not $_.Compliant } | ForEach-Object { '{0}|{1}' -f $_.Entity, $_.CheckId } | Sort-Object)
}

Describe 'Hardening against the simulator' {

    Context 'the fixture lab before and after remediation' {
        Reset-HardeningSession
        $configPath = New-FakeViState
        $config = Connect-HardeningLab -ConfigPath $configPath

        $before = @(Test-VAHardening -Config $config)
        $fixed = @(Set-VAHardening -Config $config -Confirm:$false)
        $after = @(Test-VAHardening -Config $config)

        $vms = @(FakePowerCLI\Get-VM | ForEach-Object { $_.Name })
        $ssh = @(FakePowerCLI\Get-VMHostService -VMHost 'esx02.lab.local' | Where-Object { $_.Key -eq 'TSM-SSH' })[0]
        $webCopy = @(FakePowerCLI\Get-AdvancedSetting -Entity 'web-01' -Name 'isolation.tools.copy.disable')
        Reset-HardeningSession

        It 'checks every host and VM in the cluster against all twelve checks' {
            $before.Count | Should Be (3 * 6 + $vms.Count * 6)
        }
        It 'finds SSH running on esx02.lab.local' {
            $r = @($before | Where-Object { $_.Entity -eq 'esx02.lab.local' -and $_.CheckId -eq 'ESXi.disable-ssh' })
            $r[0].Compliant | Should Be $false
        }
        It 'finds no NTP servers on esx03.lab.local' {
            $r = @($before | Where-Object { $_.Entity -eq 'esx03.lab.local' -and $_.CheckId -eq 'ESXi.config-ntp' })
            $r[0].Compliant | Should Be $false
        }
        It 'finds dc01 compliant and the other VMs missing the isolation keys' {
            @($before | Where-Object { $_.Entity -eq 'dc01' -and -not $_.Compliant }).Count | Should Be 0
            foreach ($vm in @($vms | Where-Object { $_ -ne 'dc01' })) {
                $r = @($before | Where-Object { $_.Entity -eq $vm -and $_.CheckId -eq 'VM.disable-console-copy' })
                $r[0].Compliant | Should Be $false
                ($null -eq $r[0].Actual) | Should Be $true
            }
        }
        It 'leaves only NTP on esx03.lab.local non-compliant after Set-VAHardening' {
            ((Get-NonCompliantKey $after) -join ',') | Should Be 'esx03.lab.local|ESXi.config-ntp'
        }
        It 'reports the NTP finding as ReportOnly' {
            $r = @($fixed | Where-Object { $_.CheckId -eq 'ESXi.config-ntp' })
            $r.Count | Should Be 1
            $r[0].Action | Should Be 'ReportOnly'
        }
        It 'stopped SSH and set its policy to off in the simulator' {
            $ssh.Running | Should Be $false
            $ssh.Policy | Should Be 'off'
        }
        It 'created the missing VM settings in the simulator' {
            $webCopy.Count | Should Be 1
            $webCopy[0].Value | Should Be 'TRUE'
        }
    }

    Context '-WhatIf' {
        Reset-HardeningSession
        $configPath = New-FakeViState
        $config = Connect-HardeningLab -ConfigPath $configPath
        $hashBefore = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash

        $rows = @(Set-VAHardening -Config $config -WhatIf)
        $hashAfter = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        Reset-HardeningSession

        It 'changes nothing in the simulator' {
            $hashAfter | Should Be $hashBefore
        }
        It 'lists what it would fix' {
            (@($rows | Where-Object { $_.Action -eq 'WouldFix' }).Count -gt 0) | Should Be $true
            @($rows | Where-Object { $_.Action -eq 'Fixed' }).Count | Should Be 0
        }
    }
}
