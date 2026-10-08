$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
$stubPath = Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1'
. $stubPath

Describe 'PowerCLI stubs' {

    $expected = @{
        'Get-PSSnapin'        = @('Name', 'Registered')
        'Add-PSSnapin'        = @('Name')
        'Connect-VIServer'    = @('Server', 'User', 'Password', 'Credential', 'Port', 'Protocol')
        'Disconnect-VIServer' = @('Server', 'Force', 'Confirm', 'WhatIf')
        'Get-Cluster'         = @('Name', 'Location')
        'Get-VMHost'          = @('Name', 'Location', 'State')
        'Get-VM'              = @('Name', 'Location', 'Datastore')
        'Get-Template'        = @('Name', 'Location')
        'Get-Datastore'       = @('Name', 'VMHost', 'VM')
        'New-VM'              = @('Name', 'Template', 'VMHost', 'Datastore', 'Notes', 'WhatIf', 'Confirm')
        'Set-VM'              = @('VM', 'NumCpu', 'MemoryMB', 'Notes', 'WhatIf', 'Confirm')
        'Start-VM'            = @('VM', 'RunAsync', 'WhatIf', 'Confirm')
        'Stop-VM'             = @('VM', 'Kill', 'WhatIf', 'Confirm')
        'Remove-VM'           = @('VM', 'DeletePermanently', 'WhatIf', 'Confirm')
        'Move-VM'             = @('VM', 'Destination', 'Datastore', 'WhatIf', 'Confirm')
        'Get-Snapshot'        = @('VM', 'Name')
        'New-Snapshot'        = @('VM', 'Name', 'Description', 'Memory', 'Quiesce', 'WhatIf', 'Confirm')
        'Remove-Snapshot'     = @('Snapshot', 'RemoveChildren', 'WhatIf', 'Confirm')
        'Get-Stat'            = @('Entity', 'Stat', 'Start', 'Finish', 'IntervalMins', 'MaxSamples', 'Realtime')
        'Get-AdvancedSetting' = @('Entity', 'Name')
        'Set-AdvancedSetting' = @('AdvancedSetting', 'Value', 'WhatIf', 'Confirm')
        'New-AdvancedSetting' = @('Entity', 'Name', 'Value', 'Force', 'WhatIf', 'Confirm')
        'Get-VMHostService'   = @('VMHost', 'Refresh')
        'Stop-VMHostService'  = @('HostService', 'WhatIf', 'Confirm')
        'Set-VMHostService'   = @('HostService', 'Policy', 'WhatIf', 'Confirm')
        'Get-VMHostNtpServer' = @('VMHost')
    }

    foreach ($commandName in ($expected.Keys | Sort-Object)) {
        $command = Get-Command -Name $commandName -CommandType Function -ErrorAction SilentlyContinue |
            Where-Object { $_.ScriptBlock.File -eq $stubPath } | Select-Object -First 1

        It "defines $commandName in the stubs file" {
            $command | Should Not BeNullOrEmpty
        }
        It "gives $commandName the PowerCLI 5.5 parameters" {
            foreach ($parameter in $expected[$commandName]) {
                $command.Parameters.ContainsKey($parameter) | Should Be $true
            }
        }
    }

    Context 'mocking a stub' {
        Mock Get-VM { New-Object psobject -Property @{ Name = 'mocked-vm' } }
        $result = Get-VM -Name 'anything' -Location 'Lab-Cluster'

        It 'returns what the mock provides' {
            $result.Name | Should Be 'mocked-vm'
        }
        It 'records the call with its parameters' {
            Assert-MockCalled Get-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'anything' -and $Location -eq 'Lab-Cluster' }
        }
    }

    Context 'mutating stubs honour -WhatIf through ShouldProcess' {
        It 'Remove-VM accepts -WhatIf and -Confirm:$false' {
            { Remove-VM -VM 'x' -DeletePermanently -WhatIf -Confirm:$false } | Should Not Throw
        }
    }
}
