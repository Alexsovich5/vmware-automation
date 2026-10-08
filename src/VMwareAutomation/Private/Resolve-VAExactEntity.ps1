function Resolve-VAExactEntity {
    <#
    .SYNOPSIS
        Looks up exactly one VM or host by its exact name, for callers that change it.
    .DESCRIPTION
        PowerCLI treats -Name as a wildcard pattern, so "dc0*" matches dc01, and vCenter allows
        two VMs with the same name in different folders. Before anything is changed by name:
        - a name containing a wildcard character (* ? [ ]) or the escape character (`) is
          rejected without asking vCenter;
        - the lookup result is filtered to objects whose Name equals the name (case-insensitive);
        - exactly one object must remain: none throws "Could not find", more than one throws
          an "ambiguous" error and nothing is chosen.
        Returns the inventory object; its Name is the inventory spelling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('VM', 'VMHost')]
        [string]$EntityType,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $label = 'VirtualMachine'
    if ($EntityType -eq 'VMHost') {
        $label = 'VMHost'
    }

    if (-not $Name -or -not $Name.Trim()) {
        throw ("No {0} name given." -f $label)
    }
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name) -or $Name.Contains('`')) {
        throw ('{0} name ''{1}'' contains wildcard characters (* ? [ ] or `); give the exact name.' -f $label, $Name)
    }

    if ($EntityType -eq 'VMHost') {
        $found = @(Get-VMHost -Name $Name -ErrorAction Stop)
    }
    else {
        $found = @(Get-VM -Name $Name -ErrorAction Stop)
    }

    $exact = @($found | Where-Object { $null -ne $_ -and [string]$_.Name -eq $Name })
    if ($exact.Count -eq 0) {
        throw ("Could not find {0} with name '{1}'." -f $label, $Name)
    }
    if ($exact.Count -gt 1) {
        throw ("{0} name '{1}' is ambiguous: {2} objects have that name. Nothing was changed." -f $label, $Name, $exact.Count)
    }
    $exact[0]
}
