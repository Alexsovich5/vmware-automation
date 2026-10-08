$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Read-VAConfig.ps1')
. (Join-Path $repo 'src/VMwareAutomation/Private/Select-VADatastore.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function New-TestDatastore {
    param([string]$Name, [decimal]$CapacityGB, [decimal]$FreeSpaceGB)
    New-Object psobject -Property @{ Name = $Name; CapacityGB = $CapacityGB; FreeSpaceGB = $FreeSpaceGB }
}

Describe 'Select-VADatastore' {

    $config = Read-VAConfig -Path $examplePath
    $vmHost = New-Object psobject -Property @{ Name = 'esx01.lab.local' }

    Context 'the fixture datastores on esx01' {
        Mock Get-Datastore {
            New-TestDatastore -Name 'ds-ssd01' -CapacityGB 500 -FreeSpaceGB 180
            New-TestDatastore -Name 'ds-sata01' -CapacityGB 2000 -FreeSpaceGB 700
        }

        $selected = Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-centos65'

        It 'picks the datastore with the most free space' {
            $selected.Name | Should Be 'ds-sata01'
        }
        It 'only considers datastores mounted on the host' {
            Assert-MockCalled Get-Datastore -Times 1 -Exactly -ParameterFilter { @(@($VMHost) | ForEach-Object { $_.Name }) -contains 'esx01.lab.local' }
        }
    }

    Context 'a datastore below the reserve' {
        # tpl-w2k12r2 needs 40 GB: ds-big keeps (140 - 40) / 1100 = 9.09 %, ds-small keeps (100 - 40) / 500 = 12 %.
        Mock Get-Datastore {
            New-TestDatastore -Name 'ds-big' -CapacityGB 1100 -FreeSpaceGB 140
            New-TestDatastore -Name 'ds-small' -CapacityGB 500 -FreeSpaceGB 100
        }

        It 'is skipped even when it has the most free space' {
            (Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-w2k12r2').Name | Should Be 'ds-small'
        }
        It 'is rejected when requested explicitly' {
            { Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-w2k12r2' -Datastore 'ds-big' } |
                Should Throw "Datastore 'ds-big' would fall below the 10% free-space reserve"
        }
    }

    Context 'the reserve boundary' {
        # (56 - 16) / 400 = exactly 10 %.
        Mock Get-Datastore { New-TestDatastore -Name 'ds-edge' -CapacityGB 400 -FreeSpaceGB 56 }

        It 'accepts a datastore left at exactly the reserve' {
            (Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-centos65').Name | Should Be 'ds-edge'
        }
    }

    Context 'an explicit datastore with room' {
        Mock Get-Datastore {
            New-TestDatastore -Name 'ds-ssd01' -CapacityGB 500 -FreeSpaceGB 180
            New-TestDatastore -Name 'ds-sata01' -CapacityGB 2000 -FreeSpaceGB 700
        }

        It 'is used instead of the one with the most free space' {
            (Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-centos65' -Datastore 'ds-ssd01').Name |
                Should Be 'ds-ssd01'
        }
        It 'is rejected when the host does not mount it' {
            { Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-centos65' -Datastore 'ds-sata02' } |
                Should Throw "Datastore 'ds-sata02' is not available on host 'esx01.lab.local'"
        }
    }

    Context 'no datastore keeps the reserve' {
        Mock Get-Datastore {
            New-TestDatastore -Name 'ds-full1' -CapacityGB 500 -FreeSpaceGB 50
            New-TestDatastore -Name 'ds-full2' -CapacityGB 1000 -FreeSpaceGB 20
        }

        It 'throws naming the host and the reserve' {
            { Select-VADatastore -Config $config -VMHost $vmHost -Template 'tpl-centos65' } |
                Should Throw "no datastore on host 'esx01.lab.local' can hold 16 GB and keep the 10% free-space reserve"
        }
    }
}
