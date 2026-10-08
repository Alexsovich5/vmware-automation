<#
.SYNOPSIS
    Static check that .ps1/.psm1 files stay within PowerShell 4 syntax and cmdlets.
.DESCRIPTION
    Parses every .ps1 and .psm1 file under the given paths (files, directories or
    wildcards). Paths that do not exist are skipped. Reports parse errors, class/enum
    definitions, using statements, ::new() calls, cmdlets added after PowerShell 4
    and parameters added after PowerShell 4 to existing cmdlets.
    Each problem is printed as "file:line: reason". Exits 1 if any were found.
#>
param(
    [string[]]$Path
)

$bannedCommands = @(
    'Import-PowerShellDataFile', 'New-TemporaryFile', 'Expand-Archive', 'Compress-Archive',
    'Write-Information', 'New-Guid', 'Format-Hex', 'Get-Clipboard', 'Set-Clipboard',
    'ConvertFrom-String'
)

# Command name (and its common aliases) -> parameters that arrived after PowerShell 4.
$bannedParameters = @{
    'ConvertFrom-Json'  = @('AsHashtable')
    'Get-ChildItem'     = @('Depth')
    'gci'               = @('Depth')
    'ls'                = @('Depth')
    'dir'               = @('Depth')
    'Out-File'          = @('NoNewline')
    'Set-Content'       = @('NoNewline')
    'sc'                = @('NoNewline')
    'Add-Content'       = @('NoNewline')
    'ac'                = @('NoNewline')
    'Invoke-WebRequest' = @('SkipCertificateCheck')
    'iwr'               = @('SkipCertificateCheck')
    'curl'              = @('SkipCertificateCheck')
    'wget'              = @('SkipCertificateCheck')
    'Invoke-RestMethod' = @('SkipCertificateCheck')
    'irm'               = @('SkipCertificateCheck')
}

function Get-CanonicalCommandName {
    param([string]$Name)
    $canonical = @{
        'gci' = 'Get-ChildItem'; 'ls' = 'Get-ChildItem'; 'dir' = 'Get-ChildItem'
        'sc' = 'Set-Content'; 'ac' = 'Add-Content'
        'iwr' = 'Invoke-WebRequest'; 'curl' = 'Invoke-WebRequest'; 'wget' = 'Invoke-WebRequest'
        'irm' = 'Invoke-RestMethod'
    }
    if ($canonical.ContainsKey($Name)) { return $canonical[$Name] }
    return $Name
}

function Test-ParameterMatch {
    # True when the written parameter name is the banned name or an unambiguous
    # abbreviation of it (at least three characters).
    param([string]$Written, [string]$Banned)
    if ($Written -ieq $Banned) { return $true }
    if ($Written.Length -ge 3 -and $Banned.StartsWith($Written, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

$files = @()
foreach ($p in $Path) {
    if ([string]::IsNullOrEmpty($p)) { continue }
    if (-not (Test-Path -Path $p)) { continue }
    foreach ($item in @(Get-Item -Path $p)) {
        if ($item.PSIsContainer) {
            $files += @(Get-ChildItem -Path $item.FullName -Recurse |
                Where-Object { -not $_.PSIsContainer -and ($_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1') })
        }
        elseif ($item.Extension -eq '.ps1' -or $item.Extension -eq '.psm1') {
            $files += $item
        }
    }
}

$problems = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $name = $file.FullName
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($name, [ref]$tokens, [ref]$errors)

    foreach ($e in @($errors)) {
        if ($e -eq $null) { continue }
        [void]$problems.Add(('{0}:{1}: parse error: {2}' -f $name, $e.Extent.StartLineNumber, $e.Message))
    }
    if ($ast -eq $null) { continue }

    $found = $ast.FindAll({ $true }, $true)
    foreach ($node in $found) {
        $line = $node.Extent.StartLineNumber
        $typeName = $node.GetType().Name

        if ($typeName -eq 'TypeDefinitionAst') {
            $kind = 'class'
            if ($node.IsEnum) { $kind = 'enum' }
            [void]$problems.Add(('{0}:{1}: {2} definition is not PowerShell 4 syntax' -f $name, $line, $kind))
        }
        elseif ($typeName -eq 'UsingStatementAst') {
            [void]$problems.Add(('{0}:{1}: using statement is not PowerShell 4 syntax' -f $name, $line))
        }
        elseif ($typeName -eq 'InvokeMemberExpressionAst') {
            if ($node.Static -and $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Member.Value -ieq 'new') {
                [void]$problems.Add(('{0}:{1}: ::new() is not PowerShell 4 syntax; use New-Object' -f $name, $line))
            }
        }
        elseif ($typeName -eq 'CommandAst') {
            $commandName = $node.GetCommandName()
            if ([string]::IsNullOrEmpty($commandName)) { continue }

            foreach ($banned in $bannedCommands) {
                if ($commandName -ieq $banned) {
                    [void]$problems.Add(('{0}:{1}: {2} is not available in PowerShell 4' -f $name, $line, $banned))
                }
            }

            $key = $null
            foreach ($k in $bannedParameters.Keys) {
                if ($commandName -ieq $k) { $key = $k }
            }
            if ($key -ne $null) {
                foreach ($element in $node.CommandElements) {
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    foreach ($bannedParam in $bannedParameters[$key]) {
                        if (Test-ParameterMatch -Written $element.ParameterName -Banned $bannedParam) {
                            [void]$problems.Add(('{0}:{1}: {2} -{3} is not available in PowerShell 4' -f
                                $name, $element.Extent.StartLineNumber, (Get-CanonicalCommandName $key), $bannedParam))
                        }
                    }
                }
            }
        }
    }
}

foreach ($problem in $problems) {
    Write-Output $problem
}

if ($problems.Count -gt 0) {
    exit 1
}
exit 0
