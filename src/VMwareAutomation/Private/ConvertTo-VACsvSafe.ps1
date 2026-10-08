function ConvertTo-VACsvSafe {
    <#
    .SYNOPSIS
        Copies rows for Export-Csv so that no string cell starts a spreadsheet formula.
    .DESCRIPTION
        VM, host and datastore names come from the vCenter inventory, and anyone allowed to
        create or rename objects there picks them. A cell that starts with = + - @ TAB or CR
        is run as a formula when the CSV is opened in a spreadsheet, so such string values get
        a leading single quote. Values that are not strings (numbers, dates, $null) are copied
        unchanged. The input rows are not modified.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    $triggers = @('=', '+', '-', '@', "`t", "`r")
    foreach ($row in @($InputObject)) {
        if ($null -eq $row) {
            continue
        }
        $copy = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            $value = $property.Value
            if ($value -is [string] -and $value.Length -gt 0 -and $triggers -contains $value.Substring(0, 1)) {
                $value = "'" + $value
            }
            $copy[$property.Name] = $value
        }
        New-Object psobject -Property $copy
    }
}
