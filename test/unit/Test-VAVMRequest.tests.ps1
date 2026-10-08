$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Read-VAConfig.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Test-VAVMRequest.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

Describe 'Test-VAVMRequest' {

    $config = Read-VAConfig -Path $examplePath

    Context 'invalid requests' {
        Mock Get-VM {}

        # Name, Template, NumCpu, MemoryMB, expected message fragment
        $cases = @(
            @('ab',               'tpl-centos65', 2, 4096,  "Invalid VM name 'ab'"),
            @('a-very-long-name1','tpl-centos65', 2, 4096,  "Invalid VM name 'a-very-long-name1'"),
            @('Web-03',           'tpl-centos65', 2, 4096,  "Invalid VM name 'Web-03'"),
            @('web_03',           'tpl-centos65', 2, 4096,  "Invalid VM name 'web_03'"),
            @('web-03',           'tpl-ubuntu',   2, 4096,  "Unknown template 'tpl-ubuntu'"),
            @('web-03',           'tpl-centos65', 0, 4096,  'NumCpu 0 is outside the allowed range 1-8'),
            @('web-03',           'tpl-centos65', 9, 4096,  'NumCpu 9 is outside the allowed range 1-8'),
            @('web-03',           'tpl-centos65', 2, 256,   'MemoryMB 256 is outside the allowed range 512-32768'),
            @('web-03',           'tpl-centos65', 2, 65536, 'MemoryMB 65536 is outside the allowed range 512-32768'),
            @('web-03',           'tpl-centos65', 2, 4097,  'MemoryMB 4097 is not a multiple of 4')
        )

        foreach ($case in $cases) {
            $name = $case[0]; $template = $case[1]; $cpu = $case[2]; $mem = $case[3]; $message = $case[4]
            It ("rejects {0}/{1}/{2}/{3} with: {4}" -f $name, $template, $cpu, $mem, $message) {
                { Test-VAVMRequest -Config $config -Name $name -Template $template -NumCpu $cpu -MemoryMB $mem } |
                    Should Throw $message
            }
        }
    }

    Context 'a template name with wildcard characters' {
        $wildConfig = Read-VAConfig -Path $examplePath
        $wildConfig.provisioning.templates | Add-Member -MemberType NoteProperty -Name 'tpl-*' -Value (New-Object psobject -Property @{ diskGB = 16 })
        Mock Get-VM {}

        It 'is rejected even when the config lists it, because New-VM would expand it' {
            { Test-VAVMRequest -Config $wildConfig -Name 'web-03' -Template 'tpl-*' -NumCpu 2 -MemoryMB 4096 } | Should Throw 'wildcard'
        }
    }

    Context 'a VM with the requested name already exists' {
        Mock Get-VM { New-Object psobject -Property @{ Name = 'web-01' } } -ParameterFilter { $Name -contains 'web-01' }

        It 'rejects the duplicate name' {
            { Test-VAVMRequest -Config $config -Name 'web-01' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 } |
                Should Throw "A VM named 'web-01' already exists"
        }
        It 'looked the name up with Get-VM' {
            Assert-MockCalled Get-VM -Times 1 -ParameterFilter { $Name -contains 'web-01' }
        }
    }

    Context 'a valid request' {
        Mock Get-VM {}

        It 'passes at the lower limits' {
            { Test-VAVMRequest -Config $config -Name 'web' -Template 'tpl-centos65' -NumCpu 1 -MemoryMB 512 } | Should Not Throw
        }
        It 'passes at the upper limits' {
            { Test-VAVMRequest -Config $config -Name 'app-0123456789a' -Template 'tpl-w2k12r2' -NumCpu 8 -MemoryMB 32768 } |
                Should Not Throw
        }
        It 'returns $true' {
            Test-VAVMRequest -Config $config -Name 'web-03' -Template 'tpl-centos65' -NumCpu 2 -MemoryMB 4096 | Should Be $true
        }
    }
}
