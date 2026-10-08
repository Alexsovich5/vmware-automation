function Export-VAHtmlReport {
    <#
    .SYNOPSIS
        Writes one static HTML status page from capacity, rightsizing, alert, hardening and
        snapshot rows.
    .DESCRIPTION
        Each of the five sections gets an <h2> and a table built with ConvertTo-Html -Fragment,
        which HTML-encodes every value. Rows are given a CSS class by severity:
          Alerts       Critical -> crit, Warning -> warn
          Right-sizing Undersized -> warn, Oversized -> info
          Hardening    only non-compliant items are listed (warn), under a "n of m checks
                       compliant" count
          Snapshot age Stale -> warn
        A section with nothing to list shows "No items". Dates are written as
        yyyy-MM-dd HH:mm:ss. The page carries its CSS inline and loads nothing external.
        The folder of -Path is created when missing. -GeneratedAt defaults to Get-VANow.
        Returns the written file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$Capacity,

        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$RightSizing,

        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$Alerts,

        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$Hardening,

        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$Snapshots,

        [datetime]$GeneratedAt
    )

    if (-not $PSBoundParameters.ContainsKey('GeneratedAt')) {
        $GeneratedAt = Get-VANow
    }
    $stamp = $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

    $encode = {
        param([string]$Text)
        [System.Net.WebUtility]::HtmlEncode($Text)
    }

    # Copies each row with dates formatted, so ConvertTo-Html does not use the culture's format.
    $flatten = {
        param([object[]]$Rows)
        foreach ($row in $Rows) {
            $copy = [ordered]@{}
            foreach ($prop in $row.PSObject.Properties) {
                $value = $prop.Value
                if ($value -is [datetime]) {
                    $value = $value.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                elseif ($value -is [array]) {
                    $value = ($value | ForEach-Object { [string]$_ }) -join ', '
                }
                $copy[$prop.Name] = $value
            }
            New-Object psobject -Property $copy
        }
    }

    $section = {
        param([string]$Title, [object[]]$Rows, [scriptblock]$RowClass, [string[]]$Property, [string]$Summary)
        $out = @(('<h2>{0}</h2>' -f (& $encode $Title)))
        if ($Summary) {
            $out += ('<p class="summary">{0}</p>' -f (& $encode $Summary))
        }
        $Rows = @($Rows | Where-Object { $null -ne $_ })
        if ($Rows.Count -eq 0) {
            $out += '<p class="clear">No items</p>'
            return $out
        }
        $flat = @(& $flatten $Rows)
        if ($Property) {
            $fragment = @($flat | ConvertTo-Html -Fragment -Property $Property)
        }
        else {
            $fragment = @($flat | ConvertTo-Html -Fragment)
        }
        $index = 0
        foreach ($line in $fragment) {
            if ($line -like '<tr><td>*') {
                $class = [string](& $RowClass $Rows[$index])
                if (-not $class) {
                    $class = 'ok'
                }
                $line = '<tr class="{0}">{1}' -f $class, $line.Substring(4)
                $index++
            }
            $out += $line
        }
        $out
    }

    $allHardening = @($Hardening | Where-Object { $null -ne $_ })
    $nonCompliant = @($allHardening | Where-Object { -not $_.Compliant })
    $hardeningSummary = ''
    if ($allHardening.Count -gt 0) {
        $hardeningSummary = '{0} of {1} checks compliant' -f ($allHardening.Count - $nonCompliant.Count), $allHardening.Count
    }

    $severityRank = @{ 'Critical' = 0; 'Warning' = 1 }
    $sortedAlerts = @($Alerts | Where-Object { $null -ne $_ } | Sort-Object -Property @(
        @{ Expression = { if ($severityRank.ContainsKey([string]$_.Severity)) { $severityRank[[string]$_.Severity] } else { 2 } } },
        'EntityType', 'Entity', 'Metric'
    ))

    $body = @()
    $body += & $section 'Capacity' $Capacity { 'info' }
    $body += & $section 'Right-sizing' $RightSizing {
        param($Row)
        if ($Row.Recommendation -eq 'Undersized') { 'warn' } else { 'info' }
    }
    $body += & $section 'Alerts' $sortedAlerts {
        param($Row)
        if ($Row.Severity -eq 'Critical') { 'crit' } elseif ($Row.Severity -eq 'Warning') { 'warn' } else { 'info' }
    }
    $body += & $section 'Hardening' $nonCompliant { 'warn' } @('EntityType', 'Entity', 'CheckId', 'Setting', 'Expected', 'Actual') $hardeningSummary
    $body += & $section 'Snapshot age' $Snapshots {
        param($Row)
        if ($Row.Stale) { 'warn' } else { 'ok' }
    }

    $style = @'
body { font-family: Verdana, Geneva, sans-serif; font-size: 13px; color: #222; background: #fff; margin: 16px; }
h1 { font-size: 20px; margin-bottom: 4px; }
h2 { font-size: 16px; margin: 24px 0 6px 0; border-bottom: 1px solid #999; }
p.generated { color: #555; margin-top: 0; }
p.clear { color: #2e6b2e; }
table { border-collapse: collapse; }
th, td { border: 1px solid #bbb; padding: 3px 8px; text-align: left; }
th { background: #e4e4e4; }
tr.crit td { background: #f4c7c3; }
tr.warn td { background: #fce8b2; }
tr.info td { background: #e8f0fe; }
tr.ok td { background: #ffffff; }
'@

    $page = @(
        '<!DOCTYPE html>',
        '<html>',
        '<head>',
        '<meta charset="utf-8">',
        '<title>vmware-automation status</title>',
        '<style>',
        $style,
        '</style>',
        '</head>',
        '<body>',
        '<h1>vmware-automation status</h1>',
        ('<p class="generated">Generated {0}</p>' -f $stamp)
    ) + $body + @('</body>', '</html>')

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $folder = Split-Path -Parent $fullPath
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Set-Content -Path $fullPath -Value $page -Encoding UTF8
    Get-Item -Path $fullPath
}
