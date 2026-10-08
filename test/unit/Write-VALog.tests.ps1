$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = [System.IO.Path]::GetFullPath((Join-Path $here '../../src/VMwareAutomation'))
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')

Describe 'Write-VALog' {

    $saved = $env:FAKEVI_NOW
    $env:FAKEVI_NOW = $null

    Context 'an INFO line' {
        $logDir = Join-Path $TestDrive 'info/logs'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        Write-VALog -Config $config -Source 'Test-Source' -Message 'hello world'
        $logFile = Join-Path $logDir 'vmware-automation.log'
        $lines = @(Get-Content -Path $logFile)

        It 'creates the log directory and file' {
            $logFile | Should Exist
        }
        It 'writes one line' {
            $lines.Count | Should Be 1
        }
        It 'starts with a timestamp and the level' {
            $lines[0] | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] '
        }
        It 'names the source and the message' {
            $lines[0] | Should Match '\[INFO\] Test-Source: hello world$'
        }
    }

    Context 'repeated calls and other levels' {
        $logDir = Join-Path $TestDrive 'levels'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        Write-VALog -Config $config -Source 'A' -Message 'first'
        Write-VALog -Config $config -Source 'B' -Message 'second' -Level WARN
        Write-VALog -Config $config -Source 'C' -Message 'third' -Level ERROR
        $lines = @(Get-Content -Path (Join-Path $logDir 'vmware-automation.log'))

        It 'appends instead of overwriting' {
            $lines.Count | Should Be 3
        }
        It 'writes WARN and ERROR levels' {
            $lines[1] | Should Match '\[WARN\] B: second$'
            $lines[2] | Should Match '\[ERROR\] C: third$'
        }
        It 'rejects an unknown level' {
            { Write-VALog -Config $config -Source 'D' -Message 'x' -Level DEBUG } | Should Throw
        }
    }

    Context 'the source defaults to the calling function' {
        $logDir = Join-Path $TestDrive 'caller'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        function Invoke-SomethingLogged { param($Config) Write-VALog -Config $Config -Message 'from caller' }
        Invoke-SomethingLogged -Config $config
        $line = Get-Content -Path (Join-Path $logDir 'vmware-automation.log')

        It 'uses the caller name' {
            $line | Should Match '\[INFO\] Invoke-SomethingLogged: from caller$'
        }
    }

    Context 'FAKEVI_NOW drives the timestamp' {
        $env:FAKEVI_NOW = '2014-05-12T09:30:15'
        $logDir = Join-Path $TestDrive 'clock'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        Write-VALog -Config $config -Source 'S' -Message 'tick'
        $env:FAKEVI_NOW = $null
        $line = Get-Content -Path (Join-Path $logDir 'vmware-automation.log')

        It 'stamps the line with the simulated time' {
            $line | Should Match '^2014-05-12 09:30:15 \[INFO\] S: tick$'
        }
    }

    Context 'the line is echoed to the verbose stream' {
        $logDir = Join-Path $TestDrive 'verbose'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        $verbose = @(Write-VALog -Config $config -Source 'V' -Message 'shown' -Verbose 4>&1)

        It 'emits one verbose record with the log line' {
            $verbose.Count | Should Be 1
            "$($verbose[0])" | Should Match '\[INFO\] V: shown$'
        }
    }

    Context 'a caller running under -WhatIf' {
        $logDir = Join-Path $TestDrive 'whatif'
        $config = New-Object PSObject -Property @{ logDir = $logDir }
        function Invoke-WhatIfCaller {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param($Config)
            Write-VALog -Config $Config -Message 'planned'
        }
        Invoke-WhatIfCaller -Config $config -WhatIf
        $logFile = Join-Path $logDir 'vmware-automation.log'

        It 'still writes the log line' {
            $logFile | Should Exist
            (Get-Content -Path $logFile) | Should Match 'Invoke-WhatIfCaller: planned$'
        }
    }

    Context 'no log directory configured' {
        $config = New-Object PSObject -Property @{ cluster = 'x' }

        It 'does not throw' {
            { Write-VALog -Config $config -Source 'N' -Message 'nowhere' } | Should Not Throw
        }
    }

    $env:FAKEVI_NOW = $saved
}
