function Import-VAPowerCLI {
    <#
    .SYNOPSIS
        Loads the PowerCLI cmdlets: the VMware.VimAutomation.Core snap-in when it is registered,
        otherwise the module named by $env:VA_POWERCLI_MODULE.
    .DESCRIPTION
        Get-PSSnapin is looked up first, so a host without snap-in support goes straight to the
        module override instead of failing with CommandNotFound. The module is imported into the
        global scope so entry scripts and module functions see the same cmdlets.
    #>
    [CmdletBinding()]
    param()

    $snapinName = 'VMware.VimAutomation.Core'

    if (Get-Command -Name Get-PSSnapin -ErrorAction SilentlyContinue) {
        $registered = @(Get-PSSnapin -Registered -Name $snapinName -ErrorAction SilentlyContinue)
        if ($registered.Count -gt 0) {
            Add-PSSnapin -Name $snapinName
            return
        }
    }

    $modulePath = $env:VA_POWERCLI_MODULE
    if (-not $modulePath) {
        throw ("PowerCLI is not available: the {0} snap-in is not registered and VA_POWERCLI_MODULE is not set. Install PowerCLI 5.5 or set VA_POWERCLI_MODULE to a module manifest." -f $snapinName)
    }
    if (-not (Test-Path -Path $modulePath -PathType Leaf)) {
        throw ("PowerCLI is not available: the {0} snap-in is not registered and VA_POWERCLI_MODULE points at a missing file: {1}" -f $snapinName, $modulePath)
    }
    Import-Module -Name $modulePath -Global -Force
}
