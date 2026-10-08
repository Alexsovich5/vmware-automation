function Write-VALog {
    <#
    .SYNOPSIS
        Appends "yyyy-MM-dd HH:mm:ss [LEVEL] <source>: <message>" to <logDir>/vmware-automation.log
        and echoes the same line to the verbose stream.
    .DESCRIPTION
        The source defaults to the name of the calling function. When the config has no
        logDir the line only goes to the verbose stream. The file write ignores -WhatIf,
        so a caller running under -WhatIf still records what it planned to do.
    #>
    [CmdletBinding()]
    param(
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Source
    )

    if (-not $Source) {
        $caller = @(Get-PSCallStack)
        if ($caller.Count -gt 1 -and $caller[1].FunctionName -and $caller[1].FunctionName -ne '<ScriptBlock>') {
            $Source = $caller[1].FunctionName
        }
        else {
            $Source = 'VMwareAutomation'
        }
    }

    $line = '{0} [{1}] {2}: {3}' -f (Get-VANow).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Source, $Message
    Write-Verbose $line

    $logDir = $null
    if ($Config -and $Config.PSObject.Properties['logDir']) {
        $logDir = $Config.logDir
    }
    if (-not $logDir) {
        return
    }

    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null
    }
    Add-Content -Path (Join-Path $logDir 'vmware-automation.log') -Value $line -Encoding UTF8 -WhatIf:$false
}
