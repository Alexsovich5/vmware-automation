$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $src 'Private/Read-VAConfig.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function New-TestConfig {
    param([string]$Folder, [string]$Json)
    $dir = Join-Path $TestDrive $Folder
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir 'settings.json'
    Set-Content -Path $file -Value $Json
    $file
}

Describe 'Read-VAConfig' {

    Context 'the example config' {
        $config = Read-VAConfig -Path $examplePath

        It 'loads the required keys' {
            $config.vCenter.server | Should Be 'vcsa.lab.local'
            $config.cluster | Should Be 'Lab-Cluster'
        }
        It 'keeps nested sections' {
            $config.alerts.samples | Should Be 6
            $config.snapshots.policies[0].name | Should Be 'daily'
            $config.provisioning.templates.'tpl-w2k12r2'.diskGB | Should Be 40
        }
        It 'resolves logDir relative to the config file' {
            $config.logDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'logs')))
        }
        It 'resolves outputDir relative to the config file' {
            $config.outputDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'out')))
        }
        It 'resolves hardeningBaseline next to the config file' {
            $config.hardeningBaseline | Should Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'config/hardening-baseline.json')))
        }
        It 'records the config path it was read from' {
            $config.ConfigPath | Should Be ([System.IO.Path]::GetFullPath($examplePath))
        }
    }

    Context 'a config copied into a config folder with a baseline' {
        $dir = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -Path $examplePath -Destination (Join-Path $dir 'settings.json')
        Set-Content -Path (Join-Path $dir 'hardening-baseline.json') -Value '{}'
        $config = Read-VAConfig -Path (Join-Path $dir 'settings.json')

        It 'resolves the baseline to the existing file' {
            $config.hardeningBaseline | Should Exist
            $config.hardeningBaseline | Should Be ([System.IO.Path]::GetFullPath((Join-Path $dir 'hardening-baseline.json')))
        }
        It 'sends logs and output next to the config folder' {
            $config.logDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'logs')))
            $config.outputDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'out')))
        }
    }

    Context 'an absolute logDir' {
        $abs = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'abs-logs'))
        $json = '{ "vCenter": { "server": "vc" }, "cluster": "c", "logDir": "' + ($abs -replace '\\', '\\') + '" }'
        $file = New-TestConfig -Folder 'absolute' -Json $json

        It 'is kept as given' {
            (Read-VAConfig -Path $file).logDir | Should Be $abs
        }
    }

    Context 'a missing vCenter.server' {
        $file = New-TestConfig -Folder 'noserver' -Json '{ "vCenter": { "user": "u" }, "cluster": "c" }'

        It 'throws naming the key' {
            { Read-VAConfig -Path $file } | Should Throw 'vCenter.server'
        }
    }

    Context 'a missing vCenter section' {
        $file = New-TestConfig -Folder 'novcenter' -Json '{ "cluster": "c" }'

        It 'throws naming the key' {
            { Read-VAConfig -Path $file } | Should Throw 'vCenter.server'
        }
    }

    Context 'a missing cluster' {
        $file = New-TestConfig -Folder 'nocluster' -Json '{ "vCenter": { "server": "vc" } }'

        It 'throws naming the key' {
            { Read-VAConfig -Path $file } | Should Throw 'cluster'
        }
    }

    Context 'invalid JSON' {
        $file = New-TestConfig -Folder 'badjson' -Json '{ "vCenter": { "server": "vc" , '

        It 'throws naming the file' {
            $message = ''
            try { Read-VAConfig -Path $file } catch { $message = $_.Exception.Message }
            $message | Should Match ([regex]::Escape($file))
            $message | Should Match 'JSON'
        }
    }

    Context 'an empty file' {
        $file = New-TestConfig -Folder 'empty' -Json ''

        It 'throws naming the file' {
            $message = ''
            try { Read-VAConfig -Path $file } catch { $message = $_.Exception.Message }
            $message | Should Match ([regex]::Escape($file))
        }
    }

    Context 'a missing file' {
        $file = Join-Path $TestDrive 'nothere/settings.json'

        It 'throws naming the file' {
            $message = ''
            try { Read-VAConfig -Path $file } catch { $message = $_.Exception.Message }
            $message | Should Match ([regex]::Escape($file))
            $message | Should Match 'not found'
        }
    }

    Context 'a minimal config' {
        $file = New-TestConfig -Folder 'minimal/config' -Json '{ "vCenter": { "server": "vc" }, "cluster": "c" }'
        $config = Read-VAConfig -Path $file
        $dir = Split-Path -Parent $file

        It 'defaults the vCenter password variable' {
            $config.vCenter.passwordEnv | Should Be 'VA_VCENTER_PASSWORD'
        }
        It 'defaults logDir, outputDir and hardeningBaseline' {
            $config.logDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $dir '../logs')))
            $config.outputDir | Should Be ([System.IO.Path]::GetFullPath((Join-Path $dir '../out')))
            $config.hardeningBaseline | Should Be ([System.IO.Path]::GetFullPath((Join-Path $dir 'hardening-baseline.json')))
        }
        It 'defaults the optional sections' {
            $config.alerts.samples | Should Be 6
            $config.alerts.smtp.server | Should Be ''
            $config.snapshots.prefix | Should Be 'auto'
            @($config.snapshots.policies).Count | Should Be 0
            $config.loadBalance.maxMigrations | Should Be 3
            $config.capacity.haReserveHosts | Should Be 1
            $config.rightsizing.days | Should Be 7
            $config.provisioning.limits.maxCpu | Should Be 8
        }
    }

    Context 'a partial optional section' {
        $json = '{ "vCenter": { "server": "vc" }, "cluster": "c", "alerts": { "samples": 3, "smtp": { "server": "mail" } } }'
        $file = New-TestConfig -Folder 'partial' -Json $json
        $config = Read-VAConfig -Path $file

        It 'keeps the given values' {
            $config.alerts.samples | Should Be 3
            $config.alerts.smtp.server | Should Be 'mail'
        }
        It 'fills the missing nested values' {
            $config.alerts.smtp.port | Should Be 25
            $config.alerts.datastoreFreePct.crit | Should Be 10
            $config.alerts.host.'cpu.usage.average'.warn | Should Be 75
        }
    }
}
