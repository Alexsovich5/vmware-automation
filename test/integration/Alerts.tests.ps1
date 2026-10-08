$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$manifestPath = Join-Path $repo 'src/VMwareAutomation/VMwareAutomation.psd1'

function Reset-AlertSession {
    Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
    Remove-Module FakePowerCLI -ErrorAction SilentlyContinue
    $global:DefaultVIServer = $null
    $global:DefaultVIServers = $null
}

Describe 'Get-VAPerformanceAlert against the simulator' {

    Context 'the fixture lab with FAKEVI_NOW set and no -Now' {
        Reset-AlertSession
        $configPath = New-FakeViState
        $module = Import-Module $manifestPath -Global -Force -PassThru
        $config = & $module { param($Path) Read-VAConfig -Path $Path } $configPath
        & $module { Import-VAPowerCLI }
        $null = Connect-VAvCenter -Config $config
        $rows = @(Get-VAPerformanceAlert -Config $config)
        Reset-AlertSession

        It 'reports esx03.lab.local memory as Critical' {
            $a = @($rows | Where-Object { $_.Entity -eq 'esx03.lab.local' })
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Critical'
            $a[0].EntityType | Should Be 'VMHost'
            $a[0].Metric | Should Be 'mem.usage.average'
            ($a[0].Value -ge 95) | Should Be $true
            $a[0].Timestamp | Should Be ([datetime]'2014-03-15T02:00:00')
        }
        It 'reports ds-sata02 at 15% free as a Warning' {
            $a = @($rows | Where-Object { $_.Entity -eq 'ds-sata02' })
            $a.Count | Should Be 1
            $a[0].Severity | Should Be 'Warning'
            $a[0].Value | Should Be 15
        }
        It 'reports nothing else' {
            $rows.Count | Should Be 2
        }
    }
}
