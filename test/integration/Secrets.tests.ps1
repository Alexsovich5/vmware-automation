$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$sentinel = 'S3NTINEL-pw'

# Runs an entry script in its own non-interactive pwsh process with -Verbose, so the log lines
# echoed to the verbose stream are captured too.
function Invoke-EntryScript {
    param([string]$Script, [string[]]$Argument)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo $Script) @Argument -Verbose 2>&1
    New-Object psobject -Property @{ Script = $Script; ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

function Invoke-AllEntryScripts {
    param([string]$ConfigPath)
    $requests = Join-Path $repo 'config/requests.example.csv'
    @(
        (Invoke-EntryScript 'config/Connect-vCenter.ps1' @('-ConfigPath', $ConfigPath)),
        (Invoke-EntryScript 'scripts/Invoke-Provisioning.ps1' @('-ConfigPath', $ConfigPath, '-RequestPath', $requests)),
        (Invoke-EntryScript 'scripts/Invoke-SnapshotRotation.ps1' @('-ConfigPath', $ConfigPath)),
        (Invoke-EntryScript 'scripts/Invoke-LoadBalance.ps1' @('-ConfigPath', $ConfigPath)),
        (Invoke-EntryScript 'scripts/Invoke-HealthCheck.ps1' @('-ConfigPath', $ConfigPath))
    )
}

# Names of the files under logs/ and out/ that contain the sentinel.
function Find-SentinelInFiles {
    foreach ($folder in @('logs', 'out')) {
        $path = Join-Path $TestDrive $folder
        if (Test-Path -Path $path) {
            foreach ($file in @(Get-ChildItem -Path $path -Recurse -File)) {
                if (((Get-Content -Path $file.FullName) -join "`n").Contains($sentinel)) {
                    $file.FullName
                }
            }
        }
    }
}

function Find-SentinelInOutput {
    param([object[]]$Runs)
    foreach ($run in $Runs) {
        if ($run.Output.Contains($sentinel)) {
            $run.Script
        }
    }
}

Describe 'vCenter credentials in output and logs' {

    Context 'a wrong password (authentication failure)' {
        $configPath = New-FakeViState
        $env:VA_VCENTER_PASSWORD = $sentinel
        $runs = @(Invoke-AllEntryScripts -ConfigPath $configPath)

        It 'makes every entry script fail' {
            @($runs | Where-Object { $_.ExitCode -eq 0 }).Count | Should Be 0
            ($runs[-1].Output) | Should Match 'incorrect user name or password'
        }
        It 'keeps the password out of stdout, stderr and verbose output' {
            @(Find-SentinelInOutput -Runs $runs).Count | Should Be 0
        }
        It 'keeps the password out of the log and output files' {
            @(Find-SentinelInFiles).Count | Should Be 0
        }
    }

    Context 'an unreachable vCenter' {
        $configPath = New-FakeViState
        $env:VA_VCENTER_PASSWORD = $sentinel
        $config = (Get-Content -Path $configPath) -join "`n" | ConvertFrom-Json
        $config.vCenter.server = 'vcsa-gone.lab.local'
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        $runs = @(Invoke-AllEntryScripts -ConfigPath $configPath)

        It 'makes every entry script fail' {
            @($runs | Where-Object { $_.ExitCode -eq 0 }).Count | Should Be 0
            ($runs[-1].Output) | Should Match 'vcsa-gone'
        }
        It 'keeps the password out of every output and file' {
            @(Find-SentinelInOutput -Runs $runs).Count | Should Be 0
            @(Find-SentinelInFiles).Count | Should Be 0
        }
    }

    Context 'the correct password' {
        $configPath = New-FakeViState -Mutate {
            param($State)
            $State.vCenter.password = 'S3NTINEL-pw'
        }
        $env:VA_VCENTER_PASSWORD = $sentinel
        $runs = @(Invoke-AllEntryScripts -ConfigPath $configPath)

        It 'connects (the health check reaches its CRITICAL result)' {
            $runs[-1].ExitCode | Should Be 2
        }
        It 'keeps the password out of every output and file' {
            @(Find-SentinelInOutput -Runs $runs).Count | Should Be 0
            @(Find-SentinelInFiles).Count | Should Be 0
        }
    }
}
