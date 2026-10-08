function Get-VANow {
    <#
    .SYNOPSIS
        Returns the current time, or the simulated time in $env:FAKEVI_NOW when it is set.
    #>
    [CmdletBinding()]
    param()

    if ($env:FAKEVI_NOW) {
        return [datetime]$env:FAKEVI_NOW
    }
    Get-Date
}
