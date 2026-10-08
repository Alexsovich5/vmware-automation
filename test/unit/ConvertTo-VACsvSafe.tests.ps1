$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'src/VMwareAutomation/Private/ConvertTo-VACsvSafe.ps1')

Describe 'ConvertTo-VACsvSafe' {

    Context 'string cells that a spreadsheet would run as a formula' {
        $rows = @(
            (New-Object psobject -Property ([ordered]@{ Name = '=HYPERLINK("http://x","y")'; Note = 'ok' })),
            (New-Object psobject -Property ([ordered]@{ Name = '+1+2'; Note = '-3' })),
            (New-Object psobject -Property ([ordered]@{ Name = '@SUM(A1)'; Note = "`tTab" })),
            (New-Object psobject -Property ([ordered]@{ Name = "`rCR"; Note = 'web-01' }))
        )
        $safe = @(ConvertTo-VACsvSafe -InputObject $rows)

        It 'prefixes = + - @ TAB and CR with a single quote' {
            $safe[0].Name | Should BeExactly '''=HYPERLINK("http://x","y")'
            $safe[1].Name | Should BeExactly '''+1+2'
            $safe[1].Note | Should BeExactly '''-3'
            $safe[2].Name | Should BeExactly '''@SUM(A1)'
            $safe[2].Note | Should BeExactly ("'" + "`tTab")
            $safe[3].Name | Should BeExactly ("'" + "`rCR")
        }
        It 'leaves ordinary text unchanged, including a hyphen inside a name' {
            $safe[0].Note | Should BeExactly 'ok'
            $safe[3].Note | Should BeExactly 'web-01'
        }
        It 'keeps the property order' {
            (@($safe[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Be 'Name,Note'
        }
        It 'does not change the input rows' {
            $rows[0].Name | Should BeExactly '=HYPERLINK("http://x","y")'
        }
    }

    Context 'values that are not strings' {
        $row = New-Object psobject -Property ([ordered]@{ Value = [double]-5.5; Count = 3; Missing = $null })
        $safe = ConvertTo-VACsvSafe -InputObject @($row)

        It 'keeps numbers as numbers' {
            $safe.Value | Should Be -5.5
            ($safe.Value -is [double]) | Should Be $true
            $safe.Count | Should Be 3
        }
        It 'keeps $null' {
            $safe.Missing | Should BeNullOrEmpty
        }
    }
}
