$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$manifestPath = Join-Path $repo 'src/VMwareAutomation/VMwareAutomation.psd1'

function Reset-CapacitySession {
    Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

function Connect-CapacityLab {
    param([string]$ConfigPath)
    $module = Import-Module $manifestPath -Global -Force -PassThru
    $config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
    & $module { Import-VAPowerCLI }
    $null = Connect-VAvCenter -Config $config
    $config
}

Describe 'Capacity and rightsizing against FakePowerCLI' {

    Context 'the capacity report for Lab-Cluster' {
        Reset-CapacitySession
        $config = Connect-CapacityLab -ConfigPath (New-FakeViState)
        $report = @(Get-VACapacityReport -Config $config)

        It 'returns one row for Lab-Cluster' {
            $report.Count | Should Be 1
            $report[0].Cluster | Should Be 'Lab-Cluster'
        }
        It 'totals the three hosts' {
            $report[0].Hosts | Should Be 3
            $report[0].CpuTotalMhz | Should Be 104000
            $report[0].CpuUsedMhz | Should Be 17300
            $report[0].MemoryTotalGB | Should Be 224
            $report[0].MemoryUsedGB | Should Be 122
        }
        It 'keeps esx03 (96 GB) back as the N+1 reserve' {
            $report[0].UsableMemoryGB | Should Be 128
        }
        It 'counts the 12 powered-on VMs and their 27 vCPUs on 40 cores' {
            $report[0].VMs | Should Be 12
            $report[0].vCPUs | Should Be 27
            $report[0].PCores | Should Be 40
        }
        It 'totals the free space of the three datastores' {
            $report[0].DatastoreFreeGB | Should Be 1030
        }
        It 'fits one more standard VM, limited by memory' {
            $report[0].StandardVmsThatFit | Should Be 1
            $report[0].LimitedBy | Should Be 'Memory'
        }
        Reset-CapacitySession
    }

    Context 'rightsizing with FAKEVI_NOW and no -Now' {
        Reset-CapacitySession
        $config = Connect-CapacityLab -ConfigPath (New-FakeViState)
        $rows = @(Find-VARightSizingCandidate -Config $config)
        $idle = @($rows | Where-Object { $_.VM -eq 'app-idle01' })
        $busy = @($rows | Where-Object { $_.VM -eq 'app-busy01' })

        It 'finds the fixture samples and flags exactly app-idle01 and app-busy01' {
            (@($rows | ForEach-Object { $_.VM } | Sort-Object) -join ',') | Should Be 'app-busy01,app-idle01'
        }
        It 'recommends 2 vCPU and 8192 MB for app-idle01' {
            $idle[0].Recommendation | Should Be 'Oversized'
            $idle[0].RecommendedNumCpu | Should Be 2
            $idle[0].RecommendedMemoryMB | Should Be 8192
            ($idle[0].CpuAvgPct -lt 10) | Should Be $true
            ($idle[0].CpuPeakPct -lt 30) | Should Be $true
            ($idle[0].MemAvgPct -lt 20) | Should Be $true
        }
        It 'recommends 2 vCPU and unchanged memory for app-busy01' {
            $busy[0].Recommendation | Should Be 'Undersized'
            $busy[0].RecommendedNumCpu | Should Be 2
            $busy[0].RecommendedMemoryMB | Should Be 8192
            ($busy[0].CpuAvgPct -gt 80) | Should Be $true
        }
        Reset-CapacitySession
    }

    Context 'rightsizing with -Now a month after the samples' {
        Reset-CapacitySession
        $config = Connect-CapacityLab -ConfigPath (New-FakeViState)
        $rows = @(Find-VARightSizingCandidate -Config $config -Now ([datetime]'2014-04-15T02:00:00'))

        It 'finds no samples in the window and flags nothing' {
            $rows.Count | Should Be 0
        }
        Reset-CapacitySession
    }
}
