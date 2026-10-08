$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Invoke-Demo.ps1'

Describe 'scripts/Invoke-Demo.ps1' {

    Context 'run against the simulator with the test config' {
        $configPath = New-FakeViState -Mutate {
            param($State)
            # Proves the demo reseeds the state from the fixture before it starts.
            $State.vms = @($State.vms | Where-Object { $_.name -ne 'test-01' })
        }
        $ErrorActionPreference = 'Continue'
        $output = & pwsh -NoProfile -NonInteractive -File $script -ConfigPath $configPath 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output | Out-String
        $state = (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
        $vmNames = @($state.vms | ForEach-Object { $_.name })

        It 'exits 0' {
            $exitCode | Should Be 0
        }
        It 'leaves report.html under the config outputDir' {
            (Join-Path $TestDrive 'out/report.html') | Should Exist
        }
        It 'provisions web-03 from the example CSV' {
            ($vmNames -contains 'web-03') | Should Be $true
        }
        It 'deprovisions test-01, which only exists after reseeding from the fixture' {
            ($vmNames -contains 'test-01') | Should Be $false
            $text | Should Match 'test-01'
        }
        It 'reports the health check status code without propagating it' {
            $text | Should Match 'Health check exit code: [0-3]'
        }
        It 'prints a before and after summary' {
            $text | Should Match 'Before'
            $text | Should Match 'After'
        }
    }
}
