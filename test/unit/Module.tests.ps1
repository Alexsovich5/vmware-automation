$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = [System.IO.Path]::GetFullPath((Join-Path $here '../../src/VMwareAutomation/VMwareAutomation.psd1'))

Describe 'VMwareAutomation module' {

    Context 'the manifest' {
        It 'exists' {
            $manifestPath | Should Exist
        }

        $manifest = Invoke-Expression (Get-Content -Path $manifestPath | Out-String)

        It 'targets PowerShell 4.0' {
            $manifest.PowerShellVersion | Should Be '4.0'
        }
        It 'loads the script module' {
            $manifest.RootModule | Should Be 'VMwareAutomation.psm1'
        }
    }

    Context 'Import-Module' {
        Remove-Module VMwareAutomation -ErrorAction SilentlyContinue
        $manifest = Invoke-Expression (Get-Content -Path $manifestPath | Out-String)
        $expected = @($manifest.FunctionsToExport | Sort-Object)
        $module = Import-Module $manifestPath -PassThru -Force
        $exported = @($module.ExportedFunctions.Keys | Sort-Object)
        $privateNames = @(Get-ChildItem -Path (Join-Path (Split-Path -Parent $manifestPath) 'Private') -Filter '*.ps1' |
            ForEach-Object { $_.BaseName })
        $loaded = @(& $module { Get-Command -CommandType Function | ForEach-Object { $_.Name } })
        Remove-Module VMwareAutomation -ErrorAction SilentlyContinue

        It 'imports under the module name' {
            $module.Name | Should Be 'VMwareAutomation'
        }
        It 'exports exactly the manifest function list' {
            ($exported -join ',') | Should Be ($expected -join ',')
        }
        It 'loads the private helpers into the module scope' {
            ($privateNames.Count -gt 0) | Should Be $true
            foreach ($name in $privateNames) {
                ($loaded -contains $name) | Should Be $true
            }
        }
        It 'does not export the private helpers' {
            foreach ($name in $privateNames) {
                ($exported -contains $name) | Should Be $false
            }
        }
    }
}
