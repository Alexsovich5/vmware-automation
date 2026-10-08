<#
.SYNOPSIS
    Runs every entry script, in order, against the FakePowerCLI simulator.
.DESCRIPTION
    Seeds the simulator by copying simulator/fixtures/lab-inventory.json to $env:FAKEVI_STATE,
    prints a summary of the lab, then runs Deploy-Automation, Invoke-Provisioning (with
    config/requests.example.csv), Invoke-SnapshotRotation, Invoke-LoadBalance and
    Invoke-HealthCheck, each in its own pwsh process with -ConfigPath, and prints the
    summary again.
    The environment must point PowerCLI at the simulator: VA_POWERCLI_MODULE, FAKEVI_STATE,
    FAKEVI_NOW and VA_VCENTER_PASSWORD (docker-compose.yml sets them for the demo service).
    Exit code: 0 when every step ran; the health check's own 0/1/2/3 status is printed, not
    propagated. 1 when the environment is incomplete or any other step fails.
.EXAMPLE
    docker compose up demo
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'config/settings.example.json'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not [System.IO.Path]::IsPathRooted($ConfigPath) -and -not (Test-Path -Path $ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

foreach ($name in @('VA_POWERCLI_MODULE', 'FAKEVI_STATE', 'FAKEVI_NOW', 'VA_VCENTER_PASSWORD')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        Write-Output ('Demo needs the environment variable {0}; see the demo service in docker-compose.yml.' -f $name)
        exit 1
    }
}

function Write-DemoSummary {
    param([string]$Title)

    $state = (Get-Content -Path $env:FAKEVI_STATE) -join "`n" | ConvertFrom-Json
    Write-Output ''
    Write-Output ('== {0} ==' -f $Title)
    Write-Output ('VMs: {0}   snapshots: {1}' -f @($state.vms).Count, @($state.snapshots).Count)
    $rows = foreach ($vmHost in @($state.hosts)) {
        $onHost = @($state.vms | Where-Object { $_.host -eq $vmHost.name -and $_.powerState -eq 'PoweredOn' })
        $memoryMB = ($onHost | Measure-Object -Property memoryMB -Sum).Sum
        if (-not $memoryMB) {
            $memoryMB = 0
        }
        New-Object psobject -Property @{
            Host               = $vmHost.name
            PoweredOnVMs       = $onHost.Count
            AllocatedMemoryMB  = $memoryMB
            AllocatedMemoryPct = [math]::Round(100 * $memoryMB / $vmHost.memoryTotalMB, 1)
        }
    }
    $rows | Format-Table -AutoSize Host, PoweredOnVMs, AllocatedMemoryMB, AllocatedMemoryPct |
        Out-String -Width 200 | Write-Output
}

function Invoke-DemoStep {
    param(
        [string]$Title,
        [string]$Script,
        [string[]]$Argument
    )

    Write-Output ''
    Write-Output ('== {0} ==' -f $Title)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $repoRoot $Script) @Argument 2>&1
    $script:stepExitCode = $LASTEXITCODE
    $output | ForEach-Object { [string]$_ } | Write-Output
}

# Start every run from the same lab.
Copy-Item -Path (Join-Path $repoRoot 'simulator/fixtures/lab-inventory.json') -Destination $env:FAKEVI_STATE -Force
Write-Output ('Seeded {0} from simulator/fixtures/lab-inventory.json; FAKEVI_NOW={1}' -f $env:FAKEVI_STATE, $env:FAKEVI_NOW)

Write-DemoSummary -Title 'Before'

$steps = @(
    @{ Title = 'Deploy-Automation'; Script = 'scripts/Deploy-Automation.ps1'; Argument = @('-ConfigPath', $ConfigPath) },
    @{ Title = 'Invoke-Provisioning'; Script = 'scripts/Invoke-Provisioning.ps1'; Argument = @('-ConfigPath', $ConfigPath, '-RequestPath', (Join-Path $repoRoot 'config/requests.example.csv')) },
    @{ Title = 'Invoke-SnapshotRotation'; Script = 'scripts/Invoke-SnapshotRotation.ps1'; Argument = @('-ConfigPath', $ConfigPath) },
    @{ Title = 'Invoke-LoadBalance'; Script = 'scripts/Invoke-LoadBalance.ps1'; Argument = @('-ConfigPath', $ConfigPath) }
)

$failed = @()
$script:stepExitCode = 0
foreach ($step in $steps) {
    Invoke-DemoStep -Title $step.Title -Script $step.Script -Argument $step.Argument
    if ($script:stepExitCode -ne 0) {
        $failed += ('{0} (exit {1})' -f $step.Title, $script:stepExitCode)
    }
}

Invoke-DemoStep -Title 'Invoke-HealthCheck' -Script 'scripts/Invoke-HealthCheck.ps1' -Argument @('-ConfigPath', $ConfigPath)
$healthCode = $script:stepExitCode

Write-DemoSummary -Title 'After'

Write-Output ('Health check exit code: {0} (0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN)' -f $healthCode)
if ($failed.Count -gt 0) {
    Write-Output ('Demo steps failed: {0}' -f ($failed -join ', '))
    exit 1
}
Write-Output 'Demo completed.'
exit 0
