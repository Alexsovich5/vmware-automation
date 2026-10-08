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
. (Join-Path $src 'Private/ConvertTo-VACsvSafe.ps1')
. (Join-Path $src 'Public/New-VAVirtualMachine.ps1')
. (Join-Path $src 'Public/Remove-VAVirtualMachine.ps1')
. (Join-Path $src 'Public/Invoke-VAProvisioningBatch.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'
$expectedColumns = 'Action,Name,Status,Host,Datastore,Message'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config.outputDir = Join-Path $TestDrive 'out'
    $config
}

function New-RequestFile {
    param([string]$FileName, [string[]]$Line)
    $path = Join-Path $TestDrive $FileName
    $text = @('Action,Name,Template,NumCpu,MemoryMB,Datastore,Notes') + $Line
    Set-Content -Path $path -Value $text -Encoding UTF8
    $path
}

# New-VAVirtualMachine fails for 'bad-01' and returns a placed VM otherwise.
function Set-BatchMocks {
    Mock New-VAVirtualMachine {
        if ($Name -eq 'bad-01') { throw "Unknown template 'tpl-none'" }
        New-Object psobject -Property @{
            Name   = $Name
            VMHost = (New-Object psobject -Property @{ Name = 'esx01.lab.local' })
        }
    }
    Mock Get-Datastore { New-Object psobject -Property @{ Name = 'ds-sata01' } }
    Mock Remove-VAVirtualMachine {
        if ($Name -eq 'vcsa') { throw "VM 'vcsa' is protected and cannot be removed" }
    }
}

Describe 'Invoke-VAProvisioningBatch' {

    Context 'a batch with one invalid row' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'mixed.csv' -Line @(
            'Provision,web-03,tpl-centos65,2,4096,,frontend',
            'Provision,bad-01,tpl-none,2,4096,,broken',
            'Deprovision,test-01,,,,,retired',
            'Provision,web-04,tpl-centos65,1,2048,ds-ssd01,second'
        )
        $resultPath = Join-Path $TestDrive 'out/mixed-results.csv'

        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath $resultPath -Confirm:$false)

        It 'returns one result row per request row' {
            $rows.Count | Should Be 4
        }
        It 'marks the invalid row Failed with the error message' {
            $rows[1].Name | Should Be 'bad-01'
            $rows[1].Status | Should Be 'Failed'
            $rows[1].Message | Should Match "Unknown template 'tpl-none'"
        }
        It 'still processes the rows before and after it' {
            $rows[0].Status | Should Be 'Succeeded'
            $rows[2].Status | Should Be 'Succeeded'
            $rows[3].Status | Should Be 'Succeeded'
            Assert-MockCalled New-VAVirtualMachine -Times 3 -Exactly
            Assert-MockCalled Remove-VAVirtualMachine -Times 1 -Exactly
        }
        It 'records the host and datastore of provisioned VMs' {
            $rows[0].Host | Should Be 'esx01.lab.local'
            $rows[0].Datastore | Should Be 'ds-sata01'
        }
        It 'passes the request values and -Confirm:$false to New-VAVirtualMachine' {
            Assert-MockCalled New-VAVirtualMachine -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'web-03' -and $Template -eq 'tpl-centos65' -and $NumCpu -eq 2 -and $MemoryMB -eq 4096 -and
                $Notes -eq 'frontend' -and -not $Datastore -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'passes an explicit datastore on' {
            Assert-MockCalled New-VAVirtualMachine -Times 1 -Exactly -ParameterFilter { $Name -eq 'web-04' -and $Datastore -eq 'ds-ssd01' }
        }
        It 'passes -Confirm:$false to Remove-VAVirtualMachine' {
            Assert-MockCalled Remove-VAVirtualMachine -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'test-01' -and $PSBoundParameters['Confirm'] -eq $false
            }
        }
        It 'writes the result CSV' {
            $resultPath | Should Exist
            @(Import-Csv -Path $resultPath).Count | Should Be 4
        }
    }

    Context 'the result CSV' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'columns.csv' -Line @('Provision,web-03,tpl-centos65,2,4096,,frontend')
        $resultPath = Join-Path $TestDrive 'out/columns-results.csv'

        $null = Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath $resultPath -Confirm:$false
        $lines = @(Get-Content -Path $resultPath)

        It 'has exactly the SPEC columns in order' {
            $lines[0] -replace '"', '' | Should Be $expectedColumns
        }
        It 'has no type information line' {
            $lines[0] | Should Not Match '^#TYPE'
        }
        It 'has one data line per request' {
            $lines.Count | Should Be 2
        }
    }

    Context 'request values that a spreadsheet would run as formulas' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'formula.csv' -Line @(
            'Deprovision,=2+3,,,,,x',
            '@SUM(1),web-05,,,,,x'
        )
        $resultPath = Join-Path $TestDrive 'out/formula-results.csv'

        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath $resultPath -Confirm:$false)
        $written = @(Import-Csv -Path $resultPath)

        It 'writes them to the result CSV prefixed with a single quote' {
            $written[0].Name | Should BeExactly '''=2+3'
            $written[1].Action | Should BeExactly '''@SUM(1)'
        }
        It 'returns the original values to the caller' {
            $rows[0].Name | Should BeExactly '=2+3'
            $rows[1].Action | Should BeExactly '@SUM(1)'
        }
    }

    Context 'without -ResultPath' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'default.csv' -Line @('Deprovision,test-01,,,,,retired')
        $env:FAKEVI_NOW = '2014-03-15T02:00:00'

        $null = Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -Confirm:$false
        $expected = Join-Path $TestDrive 'out/provisioning-20140315-0200.csv'

        It 'writes the results under outputDir, named after the run time' {
            $expected | Should Exist
            (Get-Content -Path $expected)[0] -replace '"', '' | Should Be $expectedColumns
        }
        $env:FAKEVI_NOW = $null
    }

    Context 'an unknown Action' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'unknown.csv' -Line @(
            'Resize,web-01,,4,8192,,bigger',
            'Deprovision,test-01,,,,,retired'
        )
        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath (Join-Path $TestDrive 'out/u.csv') -Confirm:$false)

        It 'gives Failed with a message naming the action' {
            $rows[0].Status | Should Be 'Failed'
            $rows[0].Action | Should Be 'Resize'
            $rows[0].Message | Should Match "Unknown action 'Resize'"
        }
        It 'does not call either module function for that row' {
            Assert-MockCalled New-VAVirtualMachine -Times 0 -Exactly
            Assert-MockCalled Remove-VAVirtualMachine -Times 1 -Exactly
        }
        It 'still processes the next row' {
            $rows[1].Status | Should Be 'Succeeded'
        }
    }

    Context 'a Provision row with missing sizing' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'sizing.csv' -Line @('Provision,web-05,tpl-centos65,,4096,,no cpu')
        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath (Join-Path $TestDrive 'out/s.csv') -Confirm:$false)

        It 'gives Failed naming the column' {
            $rows[0].Status | Should Be 'Failed'
            $rows[0].Message | Should Match 'NumCpu'
        }
        It 'does not call New-VAVirtualMachine' {
            Assert-MockCalled New-VAVirtualMachine -Times 0 -Exactly
        }
    }

    Context 'a failed Deprovision row' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'protected.csv' -Line @('Deprovision,vcsa,,,,,no')
        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath (Join-Path $TestDrive 'out/p.csv') -Confirm:$false)

        It 'gives Failed with the refusal message' {
            $rows[0].Status | Should Be 'Failed'
            $rows[0].Message | Should Match 'protected'
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Set-BatchMocks
        $requests = New-RequestFile -FileName 'whatif.csv' -Line @(
            'Provision,web-03,tpl-centos65,2,4096,,frontend',
            'Deprovision,test-01,,,,,retired',
            'Resize,web-01,,4,8192,,bigger'
        )
        $resultPath = Join-Path $TestDrive 'out/whatif-results.csv'

        $rows = @(Invoke-VAProvisioningBatch -Config $config -RequestPath $requests -ResultPath $resultPath -WhatIf)

        It 'marks the valid rows Skipped' {
            $rows[0].Status | Should Be 'Skipped'
            $rows[1].Status | Should Be 'Skipped'
        }
        It 'still reports an unknown action as Failed' {
            $rows[2].Status | Should Be 'Failed'
        }
        It 'never calls New-VAVirtualMachine or Remove-VAVirtualMachine' {
            Assert-MockCalled New-VAVirtualMachine -Times 0 -Exactly
            Assert-MockCalled Remove-VAVirtualMachine -Times 0 -Exactly
        }
        It 'still writes the result CSV' {
            $resultPath | Should Exist
        }
    }

    Context 'a missing request file' {
        $config = Get-TestConfig
        Set-BatchMocks

        It 'throws naming the file' {
            { Invoke-VAProvisioningBatch -Config $config -RequestPath (Join-Path $TestDrive 'none.csv') -Confirm:$false } |
                Should Throw 'none.csv'
        }
    }
}
