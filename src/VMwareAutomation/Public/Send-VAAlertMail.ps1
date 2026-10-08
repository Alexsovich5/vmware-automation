function Send-VAAlertMail {
    <#
    .SYNOPSIS
        Mails a plain-text summary of alert rows with Send-MailMessage.
    .DESCRIPTION
        Does nothing when there are no alerts, when alerts.smtp.server is empty or when
        alerts.smtp.to has no recipients. Otherwise sends one message from alerts.smtp.from to
        every address in alerts.smtp.to through alerts.smtp.server and alerts.smtp.port. The
        subject counts the alerts by severity (Unknown rows, which mean no samples, are counted
        only when there are any); the body lists one alert per line, Critical first, then
        Warning, then the rest, each group by entity type, entity and metric.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [psobject[]]$Alert
    )

    $smtp = $Config.alerts.smtp
    $rows = @($Alert | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        Write-VALog -Config $Config -Message 'Alert mail: no alerts, nothing to send'
        return
    }
    if (-not $smtp -or -not $smtp.server) {
        Write-VALog -Config $Config -Message 'Alert mail: alerts.smtp.server is not set, mail skipped'
        return
    }
    $to = @($smtp.to | Where-Object { $_ })
    if ($to.Count -eq 0) {
        Write-VALog -Config $Config -Level 'WARN' -Message 'Alert mail: alerts.smtp.to has no recipients, mail skipped'
        return
    }

    $rank = @{ 'Critical' = 0; 'Warning' = 1 }
    $sorted = @($rows | Sort-Object -Property @(
        @{ Expression = { if ($rank.ContainsKey([string]$_.Severity)) { $rank[[string]$_.Severity] } else { 2 } } },
        'EntityType', 'Entity', 'Metric'
    ))
    $critical = @($sorted | Where-Object { $_.Severity -eq 'Critical' }).Count
    $warning = @($sorted | Where-Object { $_.Severity -eq 'Warning' }).Count
    $unknown = @($sorted | Where-Object { $_.Severity -eq 'Unknown' }).Count

    $counts = '{0} critical, {1} warning' -f $critical, $warning
    if ($unknown -gt 0) {
        $counts = '{0}, {1} unknown' -f $counts, $unknown
    }
    $subject = '[vmware-automation] {0}: {1}' -f $Config.cluster, $counts
    $lines = @(
        ('Cluster: {0}' -f $Config.cluster),
        ('Alerts:  {0}' -f $counts),
        ''
    )
    foreach ($row in $sorted) {
        $when = ''
        if ($row.Timestamp) {
            $when = ([datetime]$row.Timestamp).ToString('yyyy-MM-dd HH:mm:ss')
        }
        $lines += ('{0,-8} {1,-9} {2,-24} {3,-20} value {4} threshold {5} at {6}' -f
            $row.Severity, $row.EntityType, $row.Entity, $row.Metric, $row.Value, $row.Threshold, $when)
    }
    $body = $lines -join "`r`n"

    $port = 25
    if ($smtp.port) {
        $port = [int]$smtp.port
    }
    if ($PSCmdlet.ShouldProcess(($to -join ', '), ('Send alert mail "{0}" via {1}' -f $subject, $smtp.server))) {
        Send-MailMessage -To $to -From ([string]$smtp.from) -Subject $subject -Body $body -SmtpServer ([string]$smtp.server) -Port $port
        Write-VALog -Config $Config -Message ('Alert mail: sent {0} alert(s) to {1}' -f $sorted.Count, ($to -join ', '))
    }
    else {
        Write-VALog -Config $Config -Message ('WhatIf: would mail {0} alert(s) to {1}' -f $sorted.Count, ($to -join ', '))
    }
}
