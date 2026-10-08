$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'src/VMwareAutomation/Private/Get-VAStatSummary.ps1')

function New-TestSample {
    param([object]$Entity, [string]$MetricId, [double]$Value, [string]$Instance = '')
    New-Object psobject -Property @{ Entity = $Entity; MetricId = $MetricId; Value = $Value; Instance = $Instance }
}

Describe 'Get-VAStatSummary' {

    Context 'samples for two VMs and two metrics' {
        $vmA = New-Object psobject -Property @{ Name = 'app-a' }
        $samples = @(
            New-TestSample -Entity $vmA -MetricId 'cpu.usage.average' -Value 10
            New-TestSample -Entity $vmA -MetricId 'cpu.usage.average' -Value 20
            New-TestSample -Entity $vmA -MetricId 'cpu.usage.average' -Value 60
            New-TestSample -Entity $vmA -MetricId 'mem.usage.average' -Value 40
            New-TestSample -Entity 'app-b' -MetricId 'cpu.usage.average' -Value 5.5
        )
        $summary = @(Get-VAStatSummary -Sample $samples)

        It 'returns one row per entity and metric' {
            $summary.Count | Should Be 3
        }
        It 'computes average, maximum and sample count' {
            $row = @($summary | Where-Object { $_.Entity -eq 'app-a' -and $_.MetricId -eq 'cpu.usage.average' })[0]
            $row.Average | Should Be 30
            $row.Maximum | Should Be 60
            $row.Count | Should Be 3
        }
        It 'keys entities given as objects by their name' {
            $row = @($summary | Where-Object { $_.Entity -eq 'app-a' -and $_.MetricId -eq 'mem.usage.average' })[0]
            $row.Average | Should Be 40
            $row.Count | Should Be 1
        }
        It 'keys entities given as strings by the string' {
            $row = @($summary | Where-Object { $_.Entity -eq 'app-b' })[0]
            $row.Average | Should Be 5.5
            $row.Maximum | Should Be 5.5
        }
    }

    Context 'per-instance samples' {
        $samples = @(
            New-TestSample -Entity 'esx01' -MetricId 'cpu.usage.average' -Value 30
            New-TestSample -Entity 'esx01' -MetricId 'cpu.usage.average' -Value 95 -Instance '0'
            New-TestSample -Entity 'esx01' -MetricId 'cpu.usage.average' -Value 90 -Instance '1'
        )
        $summary = @(Get-VAStatSummary -Sample $samples)

        It 'uses only the aggregate (empty instance) samples' {
            $summary.Count | Should Be 1
            $summary[0].Average | Should Be 30
            $summary[0].Count | Should Be 1
        }
    }

    Context 'no samples' {
        It 'returns nothing' {
            @(Get-VAStatSummary -Sample @()).Count | Should Be 0
        }
    }
}
