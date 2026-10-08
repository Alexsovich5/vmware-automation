$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $repo 'test/stubs/PowerCLI.Stubs.ps1')
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Private/Get-VASnapshotAge.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'
$now = [datetime]'2014-03-15T02:00:00'

function New-TestSnapshot {
    param([string]$VM, [string]$Name, [double]$AgeDays)
    New-Object psobject -Property @{
        Name    = $Name
        Created = $now.AddDays(-1 * $AgeDays)
        VM      = (New-Object psobject -Property @{ Name = $VM })
    }
}

Describe 'Get-VASnapshotAge' {

    Context 'the lab snapshots' {
        $config = Read-VAConfig -Path $examplePath
        Mock Get-VM { @((New-Object psobject -Property @{ Name = 'web-01' }), (New-Object psobject -Property @{ Name = 'app01' })) }
        Mock Get-Snapshot {
            @(
                (New-TestSnapshot 'web-01' 'auto-daily-20140314-0200' 1),
                (New-TestSnapshot 'web-01' 'pre-patch' 30),
                (New-TestSnapshot 'web-01' 'pre-upgrade' 14),
                (New-TestSnapshot 'app01' 'auto-daily-20140223-0200' 20.5)
            )
        }
        Mock New-Snapshot {}
        Mock Remove-Snapshot {}

        $rows = @(Get-VASnapshotAge -Config $config -Now $now)
        $prePatch = @($rows | Where-Object { $_.Snapshot -eq 'pre-patch' })
        $daily = @($rows | Where-Object { $_.Snapshot -eq 'auto-daily-20140314-0200' })

        It 'returns one row per snapshot' {
            $rows.Count | Should Be 4
        }
        It 'reports pre-patch as a stale manual snapshot 30 days old' {
            $prePatch[0].VM | Should Be 'web-01'
            $prePatch[0].AgeDays | Should Be 30
            $prePatch[0].IsAuto | Should Be $false
            $prePatch[0].Stale | Should Be $true
            $prePatch[0].Created | Should Be $now.AddDays(-30)
        }
        It 'reports a recent auto snapshot as auto and not stale' {
            $daily[0].IsAuto | Should Be $true
            $daily[0].Stale | Should Be $false
            $daily[0].AgeDays | Should Be 1
        }
        It 'treats exactly staleDays (14) as not yet stale' {
            @($rows | Where-Object { $_.Snapshot -eq 'pre-upgrade' })[0].Stale | Should Be $false
        }
        It 'also flags an auto snapshot older than staleDays, since rotation has stopped for it' {
            $old = @($rows | Where-Object { $_.Snapshot -eq 'auto-daily-20140223-0200' })[0]
            $old.Stale | Should Be $true
            $old.AgeDays | Should Be 20
        }
        It 'lists the oldest first' {
            $rows[0].Snapshot | Should Be 'pre-patch'
        }
        It 'returns VM, Snapshot, Created, AgeDays, IsAuto and Stale' {
            (@($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Be 'VM,Snapshot,Created,AgeDays,IsAuto,Stale'
        }
        It 'calls no mutating cmdlet' {
            Assert-MockCalled New-Snapshot -Times 0 -Exactly
            Assert-MockCalled Remove-Snapshot -Times 0 -Exactly
        }
    }

    Context 'a cluster without VMs' {
        $config = Read-VAConfig -Path $examplePath
        Mock Get-VM {}
        Mock Get-Snapshot {}

        It 'returns nothing and does not ask for snapshots' {
            @(Get-VASnapshotAge -Config $config -Now $now).Count | Should Be 0
            Assert-MockCalled Get-Snapshot -Times 0 -Exactly
        }
    }
}
