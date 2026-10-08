# Loads one function per file: private helpers first, then the public functions.
# The manifest's FunctionsToExport decides what callers see.
foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path -Path $folderPath) {
        foreach ($file in @(Get-ChildItem -Path $folderPath -Filter '*.ps1' | Sort-Object Name)) {
            . $file.FullName
        }
    }
}
