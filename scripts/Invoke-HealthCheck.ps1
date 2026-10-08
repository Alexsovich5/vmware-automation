<#
.SYNOPSIS
    Runs the read-only health checks, writes the HTML status report and exits with a
    Nagios-style status code.
.DESCRIPTION
    Loads the settings file, imports VMwareAutomation and PowerCLI, connects to vCenter and
    collects the capacity report, rightsizing candidates, performance alerts, hardening
    compliance and snapshot ages. Nothing in vCenter is changed. -Now is passed to every
    time-dependent call; without it Get-VANow is used.
    Writes report.html (or -ReportPath) and alerts.csv under the config's outputDir, then
    calls Send-VAAlertMail, which does nothing when no SMTP server is configured.
    Prints one status line and exits by the worst alert severity:
      0 OK        no alerts
      1 WARNING   at least one Warning, no Critical and no Unknown
      2 CRITICAL  at least one Critical
      3 UNKNOWN   no Critical, but a host or VM returned no samples (Unknown alert) or the
                  cluster has no hosts; or the check itself failed (bad config, connection
                  error, ...)
    Hardening findings and stale snapshots appear in the report but do not change the code.
    String cells in alerts.csv that would start a spreadsheet formula (= + - @ TAB CR) get a
    leading single quote, because entity names come from the vCenter inventory.
.EXAMPLE
    .\scripts\Invoke-HealthCheck.ps1 -ConfigPath .\config\settings.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,

    [string]$ReportPath,

    [datetime]$Now
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$server = $null

try {
    $module = Import-Module (Join-Path $repoRoot 'src/VMwareAutomation/VMwareAutomation.psd1') -Global -Force -PassThru
    $config = & $module { param($Path) Read-VAConfig -Path $Path } $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('Now')) {
        $Now = & $module { Get-VANow }
    }

    & $module { Import-VAPowerCLI }
    $server = Connect-VAvCenter -Config $config

    $capacity = @(Get-VACapacityReport -Config $config)
    $rightSizing = @(Find-VARightSizingCandidate -Config $config -Now $Now)
    $alerts = @(Get-VAPerformanceAlert -Config $config -Now $Now)
    $hardening = @(Test-VAHardening -Config $config)
    $snapshots = @(& $module { param($Config, $Now) Get-VASnapshotAge -Config $Config -Now $Now } $config $Now)

    $outputDir = [string]$config.outputDir
    if (-not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    if (-not $ReportPath) {
        $ReportPath = Join-Path $outputDir 'report.html'
    }
    $report = Export-VAHtmlReport -Path $ReportPath -Capacity $capacity -RightSizing $rightSizing -Alerts $alerts `
        -Hardening $hardening -Snapshots $snapshots -GeneratedAt $Now

    $csvPath = Join-Path $outputDir 'alerts.csv'
    if ($alerts.Count -gt 0) {
        $csvRows = @($alerts | Select-Object Severity, EntityType, Entity, Metric, Value, Threshold,
            @{ Name = 'Timestamp'; Expression = { ([datetime]$_.Timestamp).ToString('yyyy-MM-dd HH:mm:ss') } })
        & $module { param($Rows) ConvertTo-VACsvSafe -InputObject $Rows } $csvRows |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        Set-Content -Path $csvPath -Value '"Severity","EntityType","Entity","Metric","Value","Threshold","Timestamp"' -Encoding UTF8
    }

    Send-VAAlertMail -Config $config -Alert $alerts -Confirm:$false
}
catch {
    Write-Output ('UNKNOWN - health check failed: {0}' -f $_.Exception.Message)
    exit 3
}
finally {
    if ($server) {
        Disconnect-VIServer -Server $server -Confirm:$false -ErrorAction SilentlyContinue
    }
}

$critical = @($alerts | Where-Object { $_.Severity -eq 'Critical' }).Count
$warning = @($alerts | Where-Object { $_.Severity -eq 'Warning' }).Count
$unknown = @($alerts | Where-Object { $_.Severity -eq 'Unknown' }).Count
$nonCompliant = @($hardening | Where-Object { -not $_.Compliant }).Count

$status = 'OK'
$code = 0
if ($critical -gt 0) {
    $status = 'CRITICAL'
    $code = 2
}
elseif ($unknown -gt 0) {
    $status = 'UNKNOWN'
    $code = 3
}
elseif ($warning -gt 0) {
    $status = 'WARNING'
    $code = 1
}

Write-Output ('{0} - {1} critical, {2} warning, {3} unknown, {4} hardening finding(s); report: {5}' -f $status, $critical, $warning, $unknown, $nonCompliant, $report.FullName)
exit $code
