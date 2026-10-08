$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $here '..') '..'))
$readmePath = Join-Path $repoRoot 'README.md'

function Get-ReadmeLayoutPath {
    param([string]$Path)
    $lines = @(Get-Content -Path $Path)
    $inSection = $false
    $inFence = $false
    $paths = @()
    foreach ($line in $lines) {
        if ($line -match '^## ') {
            if ($inSection) { break }
            if ($line -eq '## Layout') { $inSection = $true }
            continue
        }
        if (-not $inSection) { continue }
        if ($line -match '^```') {
            if ($inFence) { break }
            $inFence = $true
            continue
        }
        if ($inFence -and $line.Trim() -ne '') {
            $paths += $line.Trim()
        }
    }
    $paths
}

Describe 'README.md' {

    $text = (Get-Content -Path $readmePath) -join "`n"
    $layout = @(Get-ReadmeLayoutPath -Path $readmePath)

    It 'has a non-empty Layout block' {
        ($layout.Count -gt 0) | Should Be $true
    }

    It 'lists this test file in the Layout block' {
        ($layout -contains 'test/build/Readme.tests.ps1') | Should Be $true
    }

    It 'names only Layout paths that exist' {
        $missing = @($layout | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })
        ($missing -join ', ') | Should BeNullOrEmpty
    }

    It 'says the vSphere side is simulated' {
        $text | Should Match 'simulated'
    }

    It 'names FakePowerCLI' {
        $text | Should Match 'FakePowerCLI'
    }

    It 'has no template placeholders left' {
        $text.Contains('{{') | Should Be $false
    }

    It 'has no template rules comment left' {
        $text | Should Not Match 'Rules for this README'
    }
}
