$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = [System.IO.Path]::GetFullPath((Join-Path $here '../../src/VMwareAutomation'))
. (Join-Path $src 'Private/Get-VANow.ps1')

Describe 'Get-VANow' {

    $saved = $env:FAKEVI_NOW

    Context 'FAKEVI_NOW is set' {
        $env:FAKEVI_NOW = '2014-05-12T09:30:00'
        $result = Get-VANow
        $env:FAKEVI_NOW = $saved

        It 'returns a datetime' {
            ($result -is [datetime]) | Should Be $true
        }
        It 'returns the configured time' {
            $result | Should Be ([datetime]'2014-05-12T09:30:00')
        }
    }

    Context 'FAKEVI_NOW is not set' {
        $env:FAKEVI_NOW = $null
        $before = Get-Date
        $result = Get-VANow
        $after = Get-Date
        $env:FAKEVI_NOW = $saved

        It 'returns a datetime' {
            ($result -is [datetime]) | Should Be $true
        }
        It 'returns the current time' {
            (($result -ge $before) -and ($result -le $after)) | Should Be $true
        }
    }
}
