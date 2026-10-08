$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
$src = Join-Path $repo 'src/VMwareAutomation'
. (Join-Path $src 'Private/Get-VANow.ps1')
. (Join-Path $src 'Private/Write-VALog.ps1')
. (Join-Path $src 'Private/Read-VAConfig.ps1')
. (Join-Path $src 'Public/Send-VAAlertMail.ps1')

$examplePath = Join-Path $repo 'config/settings.example.json'

function Get-TestConfig {
    param([string]$Server = 'smtp.lab.local')
    $config = Read-VAConfig -Path $examplePath
    $config.logDir = Join-Path $TestDrive 'logs'
    $config.alerts.smtp.server = $Server
    $config.alerts.smtp.port = 2525
    $config.alerts.smtp.to = @('ops@lab.local', 'oncall@lab.local')
    $config
}

function New-TestAlert {
    param([string]$Severity, [string]$EntityType, [string]$Entity, [string]$Metric, [double]$Value, [double]$Threshold)
    New-Object psobject -Property ([ordered]@{
        Severity = $Severity; EntityType = $EntityType; Entity = $Entity; Metric = $Metric
        Value = $Value; Threshold = $Threshold; Timestamp = [datetime]'2014-03-15T02:00:00'
    })
}

function Get-TestAlerts {
    @(
        (New-TestAlert 'Warning' 'Datastore' 'ds-sata02' 'freeSpacePct' 15 20),
        (New-TestAlert 'Critical' 'VMHost' 'esx03.lab.local' 'mem.usage.average' 97.1 95)
    )
}

Describe 'Send-VAAlertMail' {

    Context 'the command' {
        It 'supports -WhatIf' {
            (Get-Command Send-VAAlertMail).Parameters.ContainsKey('WhatIf') | Should Be $true
        }
    }

    Context 'alerts and a configured server' {
        $config = Get-TestConfig
        $global:VAMail = $null
        Mock Send-MailMessage {
            $global:VAMail = New-Object psobject -Property @{
                To = @($To); From = $From; SmtpServer = $SmtpServer; Port = $Port; Subject = $Subject; Body = $Body
            }
        }

        Send-VAAlertMail -Config $config -Alert (Get-TestAlerts) -Confirm:$false
        $mail = $global:VAMail
        Remove-Variable -Name VAMail -Scope Global

        It 'sends exactly one mail' {
            Assert-MockCalled Send-MailMessage -Times 1 -Exactly
        }
        It 'uses the configured recipients, sender, server and port' {
            ($mail.To -join ';') | Should Be 'ops@lab.local;oncall@lab.local'
            $mail.From | Should Be 'vmware-automation@lab.local'
            $mail.SmtpServer | Should Be 'smtp.lab.local'
            $mail.Port | Should Be 2525
        }
        It 'counts the alerts by severity in the subject' {
            $mail.Subject | Should Match '1 critical'
            $mail.Subject | Should Match '1 warning'
        }
        It 'lists Critical alerts before Warnings in a plain-text body' {
            $mail.Body | Should Match 'esx03\.lab\.local'
            $mail.Body | Should Match 'ds-sata02'
            ($mail.Body.IndexOf('esx03.lab.local') -lt $mail.Body.IndexOf('ds-sata02')) | Should Be $true
            $mail.Body | Should Not Match '<'
        }
    }

    Context 'only Unknown alerts (no samples)' {
        $config = Get-TestConfig
        $global:VAMail = $null
        Mock Send-MailMessage {
            $global:VAMail = New-Object psobject -Property @{ Subject = $Subject; Body = $Body }
        }
        $unknown = New-Object psobject -Property ([ordered]@{
            Severity = 'Unknown'; EntityType = 'VMHost'; Entity = 'esx01.lab.local'; Metric = 'cpu.usage.average'
            Value = $null; Threshold = $null; Timestamp = [datetime]'2014-03-15T02:00:00'
        })

        Send-VAAlertMail -Config $config -Alert @($unknown) -Confirm:$false
        $mail = $global:VAMail
        Remove-Variable -Name VAMail -Scope Global

        It 'still sends a mail' {
            Assert-MockCalled Send-MailMessage -Times 1 -Exactly
        }
        It 'counts the unknown rows in the subject' {
            $mail.Subject | Should Match '1 unknown'
        }
        It 'lists the entity in the body' {
            $mail.Body | Should Match 'esx01\.lab\.local'
        }
    }

    Context 'no alerts' {
        $config = Get-TestConfig
        Mock Send-MailMessage { }

        Send-VAAlertMail -Config $config -Alert @() -Confirm:$false

        It 'sends nothing' {
            Assert-MockCalled Send-MailMessage -Times 0 -Exactly
        }
    }

    Context 'no SMTP server configured' {
        $config = Get-TestConfig -Server ''
        Mock Send-MailMessage { }

        Send-VAAlertMail -Config $config -Alert (Get-TestAlerts) -Confirm:$false

        It 'sends nothing' {
            Assert-MockCalled Send-MailMessage -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        $config = Get-TestConfig
        Mock Send-MailMessage { }

        Send-VAAlertMail -Config $config -Alert (Get-TestAlerts) -WhatIf

        It 'sends nothing' {
            Assert-MockCalled Send-MailMessage -Times 0 -Exactly
        }
    }
}
