$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Get-VAStatSummary.ps1')
. (Join-Path $src 'Public/Find-VARightSizingCandidate.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config
}

function New-TestVM {
    param([string]$Name, [int]$NumCpu, [decimal]$MemoryMB, [string]$PowerState = 'PoweredOn')
    New-Object psobject -Property @{ Name = $Name; NumCpu = $NumCpu; MemoryMB = $MemoryMB; PowerState = $PowerState }
}

function New-TestSamples {
    param([string]$Entity, [string]$MetricId, [double[]]$Values)
    $vm = New-Object psobject -Property @{ Name = $Entity }
    foreach ($v in $Values) {
        New-Object psobject -Property @{ Entity = $vm; MetricId = $MetricId; Value = $v; Instance = '' }
    }
}

function Get-Row {
    param([object[]]$Rows, [string]$Name)
    $found = @($Rows | Where-Object { $_.VM -eq $Name })
    if ($found.Count -gt 0) { $found[0] }
}

Describe 'Find-VARightSizingCandidate' {

    Context 'the rules' {
        $config = Get-TestConfig
        Mock Get-VM {
            New-TestVM -Name 'app-idle01' -NumCpu 4 -MemoryMB 16384
            New-TestVM -Name 'small-idle' -NumCpu 1 -MemoryMB 1536
            New-TestVM -Name 'app-busy01' -NumCpu 1 -MemoryMB 8192
            New-TestVM -Name 'mem-hot' -NumCpu 2 -MemoryMB 2050
            New-TestVM -Name 'mem-cap' -NumCpu 2 -MemoryMB 24576
            New-TestVM -Name 'cpu-max' -NumCpu 8 -MemoryMB 4096
            New-TestVM -Name 'mixed' -NumCpu 1 -MemoryMB 8192
            New-TestVM -Name 'normal' -NumCpu 2 -MemoryMB 4096
            New-TestVM -Name 'edge' -NumCpu 4 -MemoryMB 4096
            New-TestVM -Name 'quiet' -NumCpu 4 -MemoryMB 16384
            New-TestVM -Name 'old-01' -NumCpu 4 -MemoryMB 16384 -PowerState 'PoweredOff'
        }
        Mock Get-Stat {
            New-TestSamples -Entity 'app-idle01' -MetricId 'cpu.usage.average' -Values @(2, 3, 2, 12, 1)
            New-TestSamples -Entity 'app-idle01' -MetricId 'mem.usage.average' -Values @(9, 11)
            New-TestSamples -Entity 'small-idle' -MetricId 'cpu.usage.average' -Values @(1, 2)
            New-TestSamples -Entity 'small-idle' -MetricId 'mem.usage.average' -Values @(5)
            New-TestSamples -Entity 'app-busy01' -MetricId 'cpu.usage.average' -Values @(85, 90, 89)
            New-TestSamples -Entity 'app-busy01' -MetricId 'mem.usage.average' -Values @(50)
            New-TestSamples -Entity 'mem-hot' -MetricId 'cpu.usage.average' -Values @(40)
            New-TestSamples -Entity 'mem-hot' -MetricId 'mem.usage.average' -Values @(95)
            New-TestSamples -Entity 'mem-cap' -MetricId 'cpu.usage.average' -Values @(40)
            New-TestSamples -Entity 'mem-cap' -MetricId 'mem.usage.average' -Values @(92)
            New-TestSamples -Entity 'cpu-max' -MetricId 'cpu.usage.average' -Values @(95)
            New-TestSamples -Entity 'cpu-max' -MetricId 'mem.usage.average' -Values @(50)
            New-TestSamples -Entity 'mixed' -MetricId 'cpu.usage.average' -Values @(90)
            New-TestSamples -Entity 'mixed' -MetricId 'mem.usage.average' -Values @(5)
            New-TestSamples -Entity 'normal' -MetricId 'cpu.usage.average' -Values @(30, 50)
            New-TestSamples -Entity 'normal' -MetricId 'mem.usage.average' -Values @(50)
            New-TestSamples -Entity 'edge' -MetricId 'cpu.usage.average' -Values @(10, 10)
            New-TestSamples -Entity 'edge' -MetricId 'mem.usage.average' -Values @(20)
            New-TestSamples -Entity 'old-01' -MetricId 'cpu.usage.average' -Values @(1)
            New-TestSamples -Entity 'old-01' -MetricId 'mem.usage.average' -Values @(1)
        }

        $rows = @(Find-VARightSizingCandidate -Config $config -Now ([datetime]'2014-03-15T02:00:00'))

        It 'flags app-idle01 as Oversized with 2 vCPU and 8192 MB' {
            $row = Get-Row $rows 'app-idle01'
            $row.Recommendation | Should Be 'Oversized'
            $row.RecommendedNumCpu | Should Be 2
            $row.RecommendedMemoryMB | Should Be 8192
        }
        It 'reports the current size and the averages and peak it used' {
            $row = Get-Row $rows 'app-idle01'
            $row.NumCpu | Should Be 4
            $row.MemoryMB | Should Be 16384
            $row.CpuAvgPct | Should Be 4
            $row.CpuPeakPct | Should Be 12
            $row.MemAvgPct | Should Be 10
        }
        It 'floors a halved 1536 MB at minMemoryMB (1024) and keeps at least 1 vCPU' {
            $row = Get-Row $rows 'small-idle'
            $row.Recommendation | Should Be 'Oversized'
            $row.RecommendedMemoryMB | Should Be 1024
            $row.RecommendedNumCpu | Should Be 1
        }
        It 'flags app-busy01 as Undersized with 2 vCPU and memory unchanged' {
            $row = Get-Row $rows 'app-busy01'
            $row.Recommendation | Should Be 'Undersized'
            $row.RecommendedNumCpu | Should Be 2
            $row.RecommendedMemoryMB | Should Be 8192
        }
        It 'grows hot memory by half, rounded down to a multiple of 4 (2050 -> 3072)' {
            $row = Get-Row $rows 'mem-hot'
            $row.Recommendation | Should Be 'Undersized'
            $row.RecommendedMemoryMB | Should Be 3072
            $row.RecommendedNumCpu | Should Be 2
        }
        It 'caps grown memory at maxMemoryMB' {
            (Get-Row $rows 'mem-cap').RecommendedMemoryMB | Should Be 32768
        }
        It 'keeps a busy VM already at maxCpu at maxCpu' {
            $row = Get-Row $rows 'cpu-max'
            $row.Recommendation | Should Be 'Undersized'
            $row.RecommendedNumCpu | Should Be 8
        }
        It 'lets Undersized win when both apply, and applies each dimension''s rule' {
            $row = Get-Row $rows 'mixed'
            $row.Recommendation | Should Be 'Undersized'
            $row.RecommendedNumCpu | Should Be 2
            $row.RecommendedMemoryMB | Should Be 4096
        }
        It 'leaves VMs inside the thresholds out, including values exactly at a threshold' {
            Get-Row $rows 'normal' | Should BeNullOrEmpty
            Get-Row $rows 'edge' | Should BeNullOrEmpty
        }
        It 'skips a VM with no samples' {
            Get-Row $rows 'quiet' | Should BeNullOrEmpty
        }
        It 'ignores powered-off VMs' {
            Get-Row $rows 'old-01' | Should BeNullOrEmpty
            Assert-MockCalled Get-Stat -Times 0 -ParameterFilter { @($Entity | ForEach-Object { $_.Name }) -contains 'old-01' }
        }
        It 'returns only the flagged VMs' {
            $rows.Count | Should Be 7
        }
    }

    Context 'the query window with -Now' {
        $config = Get-TestConfig
        Mock Get-VM { New-TestVM -Name 'app-idle01' -NumCpu 4 -MemoryMB 16384 }
        Mock Get-Stat {}
        $now = [datetime]'2014-03-15T02:00:00'
        $null = Find-VARightSizingCandidate -Config $config -Now $now

        It 'asks for cpu and memory usage over rightsizing.days up to -Now' {
            Assert-MockCalled Get-Stat -Times 1 -Exactly -ParameterFilter {
                $Start -eq $now.AddDays(-7) -and $Finish -eq $now -and
                @($Stat) -contains 'cpu.usage.average' -and @($Stat) -contains 'mem.usage.average' -and
                @($Entity)[0].Name -eq 'app-idle01'
            }
        }
        It 'reads the configured cluster''s VMs' {
            Assert-MockCalled Get-VM -ParameterFilter { @($Location) -contains 'Lab-Cluster' }
        }
    }

    Context 'the query window with -Days' {
        $config = Get-TestConfig
        Mock Get-VM { New-TestVM -Name 'app-idle01' -NumCpu 4 -MemoryMB 16384 }
        Mock Get-Stat {}
        $now = [datetime]'2014-03-15T02:00:00'
        $null = Find-VARightSizingCandidate -Config $config -Days 3 -Now $now

        It 'uses -Days instead of rightsizing.days' {
            Assert-MockCalled Get-Stat -Times 1 -Exactly -ParameterFilter { $Start -eq $now.AddDays(-3) -and $Finish -eq $now }
        }
    }

    Context 'the query window without -Now' {
        $config = Get-TestConfig
        Mock Get-VM { New-TestVM -Name 'app-idle01' -NumCpu 4 -MemoryMB 16384 }
        Mock Get-Stat {}
        $saved = $env:FAKEVI_NOW
        $env:FAKEVI_NOW = '2014-03-15T02:00:00'
        $null = Find-VARightSizingCandidate -Config $config
        $env:FAKEVI_NOW = $saved

        It 'ends at the Get-VANow time' {
            Assert-MockCalled Get-Stat -Times 1 -Exactly -ParameterFilter {
                $Finish -eq [datetime]'2014-03-15T02:00:00' -and $Start -eq [datetime]'2014-03-08T02:00:00'
            }
        }
    }

    Context 'no powered-on VMs' {
        $config = Get-TestConfig
        Mock Get-VM { New-TestVM -Name 'old-01' -NumCpu 2 -MemoryMB 2048 -PowerState 'PoweredOff' }
        Mock Get-Stat {}
        $rows = @(Find-VARightSizingCandidate -Config $config -Now ([datetime]'2014-03-15T02:00:00'))

        It 'returns nothing and does not query statistics' {
            $rows.Count | Should Be 0
            Assert-MockCalled Get-Stat -Times 0
        }
    }
}
