$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Public/Export-VAHtmlReport.ps1')

function New-Row {
    param([System.Collections.IDictionary]$Property)
    New-Object psobject -Property $Property
}

function Get-SampleInput {
    @{
        Capacity    = @(New-Row ([ordered]@{ Cluster = 'Lab-Cluster'; Hosts = 3; StandardVmsThatFit = 12; LimitedBy = 'Memory' }))
        RightSizing = @(
            (New-Row ([ordered]@{ VM = 'app-idle01'; NumCpu = 4; MemoryMB = 8192; Recommendation = 'Oversized' })),
            (New-Row ([ordered]@{ VM = 'app-busy01'; NumCpu = 2; MemoryMB = 4096; Recommendation = 'Undersized' }))
        )
        Alerts      = @(
            (New-Row ([ordered]@{ Severity = 'Critical'; EntityType = 'VMHost'; Entity = 'esx03.lab.local'; Metric = 'mem.usage.average'; Value = 97.1; Threshold = 95 })),
            (New-Row ([ordered]@{ Severity = 'Warning'; EntityType = 'Datastore'; Entity = 'ds-sata02'; Metric = 'freeSpacePct'; Value = 15; Threshold = 20 }))
        )
        Hardening   = @(
            (New-Row ([ordered]@{ EntityType = 'VMHost'; Entity = 'esx02.lab.local'; CheckId = 'ESXi.disable-ssh'; Setting = 'TSM-SSH'; Expected = 'stopped/off'; Actual = 'running/on'; Compliant = $false })),
            (New-Row ([ordered]@{ EntityType = 'VM'; Entity = 'dc01'; CheckId = 'VM.disable-console-copy'; Setting = 'isolation.tools.copy.disable'; Expected = 'TRUE'; Actual = 'TRUE'; Compliant = $true }))
        )
        Snapshots   = @(New-Row ([ordered]@{ VM = 'web-01'; Snapshot = 'pre-patch'; Created = [datetime]'2014-02-20T09:00:00'; AgeDays = 22; IsAuto = $false; Stale = $true }))
    }
}

function Read-Report {
    param([string]$Path)
    (Get-Content -Path $Path) -join "`n"
}

Describe 'Export-VAHtmlReport' {

    Context 'all five sections with rows' {
        $in = Get-SampleInput
        $path = Join-Path $TestDrive 'out/report.html'
        $result = Export-VAHtmlReport -Path $path -Capacity $in.Capacity -RightSizing $in.RightSizing -Alerts $in.Alerts `
            -Hardening $in.Hardening -Snapshots $in.Snapshots -GeneratedAt ([datetime]'2014-03-15T02:00:00')
        $html = Read-Report -Path $path

        It 'creates the output folder and the file' {
            $path | Should Exist
        }
        It 'returns the written file' {
            $result.FullName | Should Be ([System.IO.Path]::GetFullPath($path))
        }
        It 'has one <h2> per section' {
            ([regex]::Matches($html, '<h2>')).Count | Should Be 5
            foreach ($title in @('Capacity', 'Right-sizing', 'Alerts', 'Hardening', 'Snapshot age')) {
                $html | Should Match ('<h2>{0}</h2>' -f [regex]::Escape($title))
            }
        }
        It 'is a complete page with inline CSS and no external resources' {
            $html | Should Match '<!DOCTYPE html'
            $html | Should Match '<style>'
            $html | Should Not Match '<link'
            $html | Should Not Match '<script'
        }
        It 'shows the generated timestamp' {
            $html | Should Match 'Generated 2014-03-15 02:00:00'
        }
        It 'colours alert rows by severity' {
            $html | Should Match '<tr class="crit"><td>Critical</td><td>VMHost</td><td>esx03\.lab\.local</td>'
            $html | Should Match '<tr class="warn"><td>Warning</td><td>Datastore</td><td>ds-sata02</td>'
        }
        It 'marks undersized VMs as warnings and oversized VMs as information' {
            $html | Should Match '<tr class="warn"><td>app-busy01</td>'
            $html | Should Match '<tr class="info"><td>app-idle01</td>'
        }
        It 'lists only non-compliant hardening items, with a compliance count' {
            $html | Should Match '<tr class="warn"><td>VMHost</td><td>esx02\.lab\.local</td><td>ESXi\.disable-ssh</td>'
            $html | Should Not Match 'VM\.disable-console-copy'
            $html | Should Match '1 of 2 checks compliant'
        }
        It 'marks stale snapshots as warnings' {
            $html | Should Match '<tr class="warn"><td>web-01</td><td>pre-patch</td>'
        }
        It 'does not show the all-clear line' {
            $html | Should Not Match 'No items'
        }
    }

    Context 'names that contain HTML characters' {
        $path = Join-Path $TestDrive 'escape.html'
        $alert = New-Row ([ordered]@{ Severity = 'Warning'; EntityType = 'VM'; Entity = 'web<01>&test'; Metric = 'cpu.usage.average'; Value = 88; Threshold = 85 })
        $snap = New-Row ([ordered]@{ VM = 'db<&>'; Snapshot = 'before "upgrade"'; Created = [datetime]'2014-03-14T02:00:00'; AgeDays = 1; IsAuto = $false; Stale = $false })
        $null = Export-VAHtmlReport -Path $path -Alerts @($alert) -Snapshots @($snap) -GeneratedAt ([datetime]'2014-03-15T02:00:00')
        $html = Read-Report -Path $path

        It 'escapes < and & in VM names' {
            $html | Should Match 'web&lt;01&gt;&amp;test'
            $html | Should Match 'db&lt;&amp;&gt;'
            $html | Should Not Match 'web<01>'
            $html | Should Not Match 'db<&>'
        }
    }

    Context 'empty sections' {
        $path = Join-Path $TestDrive 'empty.html'
        $in = Get-SampleInput
        $compliant = @($in.Hardening | Where-Object { $_.Compliant })
        $null = Export-VAHtmlReport -Path $path -Capacity $in.Capacity -Alerts @() -Hardening $compliant -GeneratedAt ([datetime]'2014-03-15T02:00:00')
        $html = Read-Report -Path $path

        It 'still has an <h2> for each of the 5 sections' {
            ([regex]::Matches($html, '<h2>')).Count | Should Be 5
        }
        It 'shows "No items" for every section without rows' {
            ([regex]::Matches($html, 'No items')).Count | Should Be 4
        }
        It 'keeps the capacity table' {
            $html | Should Match '<td>Lab-Cluster</td>'
        }
        It 'counts compliant hardening checks even with nothing to list' {
            $html | Should Match '1 of 1 checks compliant'
        }
    }

    Context 'without -GeneratedAt' {
        $path = Join-Path $TestDrive 'now.html'
        $saved = $env:FAKEVI_NOW
        $env:FAKEVI_NOW = '2014-03-16T08:30:00'
        $null = Export-VAHtmlReport -Path $path
        $env:FAKEVI_NOW = $saved
        $html = Read-Report -Path $path

        It 'stamps the report with Get-VANow' {
            $html | Should Match 'Generated 2014-03-16 08:30:00'
        }
    }
}
