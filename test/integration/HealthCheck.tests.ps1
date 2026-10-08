$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Invoke-HealthCheck.ps1'

# Runs the entry script in its own non-interactive pwsh process, as a scheduler or monitor
# would. Its stderr is captured as output, so the runner's 'Stop' preference must not turn it
# into a throw.
function Invoke-HealthCheckScript {
    param([string[]]$Argument)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File $script @Argument 2>&1
    New-Object psobject -Property @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

$lowerHostMemory = {
    param($State)
    foreach ($series in @($State.stats | Where-Object { $_.entity -eq 'esx03.lab.local' -and $_.stat -eq 'mem.usage.average' -and [int]$_.intervalSecs -eq 20 })) {
        $series.values = @($series.values | ForEach-Object { 52.5 })
    }
}

$lowerHostMemoryAndFreeDatastore = {
    param($State)
    & $lowerHostMemory $State
    foreach ($ds in @($State.datastores | Where-Object { $_.name -eq 'ds-sata02' })) {
        $ds.freeSpaceGB = 300
    }
}

$dropEsx01Realtime = {
    param($State)
    $State.stats = @($State.stats | Where-Object { -not ($_.entity -eq 'esx01.lab.local' -and [int]$_.intervalSecs -eq 20) })
}

$quietLabWithoutEsx01Samples = {
    param($State)
    & $lowerHostMemoryAndFreeDatastore $State
    & $dropEsx01Realtime $State
}

$formulaDatastore = {
    param($State)
    & $lowerHostMemoryAndFreeDatastore $State
    $State.datastores = @($State.datastores) + (New-Object psobject -Property ([ordered]@{
        name = '=HYPERLINK("http://example.invalid/","open")'; id = 'Datastore-datastore-90'; type = 'VMFS'
        capacityGB = 100; freeSpaceGB = 5; hosts = @('esx01.lab.local')
    }))
}

Describe 'scripts/Invoke-HealthCheck.ps1' {

    Context 'the fixture lab' {
        $configPath = New-FakeViState
        $before = (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath)
        $report = Join-Path $TestDrive 'out/report.html'
        $csv = Join-Path $TestDrive 'out/alerts.csv'

        It 'exits 2 because esx03.lab.local memory is critical' {
            $run.ExitCode | Should Be 2
        }
        It 'prints a CRITICAL status line' {
            $run.Output | Should Match 'CRITICAL'
        }
        It 'writes report.html under outputDir with the critical host' {
            $report | Should Exist
            $report | Should Contain 'esx03\.lab\.local'
            $report | Should Contain '<tr class="crit">'
        }
        It 'covers all five sections in the report' {
            $html = (Get-Content -Path $report) -join "`n"
            ([regex]::Matches($html, '<h2>')).Count | Should Be 5
        }
        It 'shows the stale manual snapshot and the hardening findings' {
            $report | Should Contain 'pre-patch'
            $report | Should Contain 'ESXi\.disable-ssh'
        }
        It 'writes alerts.csv with both alerts' {
            $csv | Should Exist
            $rows = @(Import-Csv -Path $csv)
            $rows.Count | Should Be 2
            ((@($rows | ForEach-Object { $_.Entity }) | Sort-Object) -join ',') | Should Be 'ds-sata02,esx03.lab.local'
        }
        It 'changes nothing in the simulator state' {
            (Get-FileHash -Path $env:FAKEVI_STATE -Algorithm SHA256).Hash | Should Be $before
        }
        It 'prints no "What if:" output' {
            $run.Output | Should Not Match 'What if:'
        }
    }

    Context 'esx03.lab.local memory lowered below warning' {
        $configPath = New-FakeViState -Mutate $lowerHostMemory
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath)

        It 'exits 1 because the ds-sata02 warning remains' {
            $run.ExitCode | Should Be 1
        }
        It 'prints a WARNING status line' {
            $run.Output | Should Match 'WARNING'
        }
    }

    Context 'host memory lowered and ds-sata02 above 20% free' {
        $configPath = New-FakeViState -Mutate $lowerHostMemoryAndFreeDatastore
        $reportPath = Join-Path $TestDrive 'custom/status.html'
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath, '-ReportPath', $reportPath)

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'prints an OK status line' {
            $run.Output | Should Match 'OK'
        }
        It 'writes the report to -ReportPath with an empty alerts section' {
            $reportPath | Should Exist
            $reportPath | Should Contain 'No items'
        }
        It 'still writes an alerts.csv under outputDir' {
            (Join-Path $TestDrive 'out/alerts.csv') | Should Exist
        }
    }

    Context 'esx01.lab.local returns no realtime samples and nothing else is wrong' {
        $configPath = New-FakeViState -Mutate $quietLabWithoutEsx01Samples
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath)
        $rows = @(Import-Csv -Path (Join-Path $TestDrive 'out/alerts.csv'))

        It 'exits 3 instead of reporting OK' {
            $run.ExitCode | Should Be 3
        }
        It 'prints an UNKNOWN status line' {
            $run.Output | Should Match 'UNKNOWN'
        }
        It 'lists the missing host metrics as Unknown in alerts.csv' {
            $rows.Count | Should Be 2
            @($rows | Where-Object { $_.Severity -eq 'Unknown' -and $_.Entity -eq 'esx01.lab.local' }).Count | Should Be 2
        }
    }

    Context 'esx01.lab.local without samples while esx03.lab.local is critical' {
        $configPath = New-FakeViState -Mutate $dropEsx01Realtime
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath)

        It 'exits 2: a known critical outranks unknown' {
            $run.ExitCode | Should Be 2
        }
    }

    Context 'a datastore whose name is a spreadsheet formula' {
        $configPath = New-FakeViState -Mutate $formulaDatastore
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath)
        $rows = @(Import-Csv -Path (Join-Path $TestDrive 'out/alerts.csv'))

        It 'raises the critical free-space alert' {
            $run.ExitCode | Should Be 2
        }
        It 'writes the name to alerts.csv prefixed with a single quote' {
            $rows.Count | Should Be 1
            $rows[0].Entity | Should BeExactly '''=HYPERLINK("http://example.invalid/","open")'
        }
        It 'keeps numeric columns as plain numbers' {
            $rows[0].Value | Should Be '5'
            $rows[0].Threshold | Should Be '10'
        }
    }

    Context '-Now passed through' {
        $configPath = New-FakeViState
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', $configPath, '-Now', '2014-03-20T02:00:00')
        $report = Join-Path $TestDrive 'out/report.html'

        It 'stamps the report with -Now' {
            $report | Should Contain 'Generated 2014-03-20 02:00:00'
        }
        It 'ages the snapshots from -Now' {
            $html = (Get-Content -Path $report) -join "`n"
            $html | Should Match '<td>auto-daily-20140305-0200</td><td>[^<]*</td><td>15</td>'
        }
    }

    Context 'a missing config file' {
        $null = New-FakeViState
        $run = Invoke-HealthCheckScript -Argument @('-ConfigPath', (Join-Path $TestDrive 'config/missing.json'))

        It 'exits 3 (unknown) instead of a status code' {
            $run.ExitCode | Should Be 3
        }
        It 'prints an UNKNOWN status line' {
            $run.Output | Should Match 'UNKNOWN'
        }
    }
}
