function Read-VAHardeningBaseline {
    <#
    .SYNOPSIS
        Reads the hardening baseline JSON file named by the config's hardeningBaseline path.
    .OUTPUTS
        The baseline object with its host and vm sections.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config
    )

    $path = [string]$Config.hardeningBaseline
    if (-not $path -or -not (Test-Path -Path $path -PathType Leaf)) {
        throw ("Hardening baseline file not found: {0}" -f $path)
    }
    try {
        $baseline = (Get-Content -Path $path) -join "`n" | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ("Hardening baseline '{0}' is not valid JSON: {1}" -f $path, $_.Exception.Message)
    }
    if (-not ($baseline -is [psobject]) -or -not $baseline.PSObject.Properties.Count) {
        throw ("Hardening baseline '{0}' is empty" -f $path)
    }
    $baseline
}
