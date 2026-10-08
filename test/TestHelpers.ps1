function New-FakeViState {
    <#
    .SYNOPSIS
        Prepares a private FakePowerCLI environment inside the current Pester $TestDrive.
    .DESCRIPTION
        Copies simulator/fixtures/lab-inventory.json to $TestDrive/fakevi-state.json and
        config/settings.example.json (plus config/hardening-baseline.json when it exists)
        to $TestDrive/config/, so the config's ../out and ../logs resolve to $TestDrive/out
        and $TestDrive/logs. Sets FAKEVI_STATE, FAKEVI_NOW, VA_POWERCLI_MODULE and
        VA_VCENTER_PASSWORD, and returns the copied config path.
    .PARAMETER Mutate
        Optional scriptblock called with the parsed state object; the changed state is
        written back to the copied state file.
    #>
    param(
        [scriptblock]$Mutate
    )

    if (-not $TestDrive) {
        throw 'New-FakeViState must be called inside a Pester Describe block.'
    }

    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $testRoot = [System.IO.Path]::GetFullPath($TestDrive)

    $statePath = Join-Path $testRoot 'fakevi-state.json'
    Copy-Item -Path (Join-Path $repoRoot 'simulator/fixtures/lab-inventory.json') -Destination $statePath -Force

    $configDir = Join-Path $testRoot 'config'
    if (-not (Test-Path -Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $configPath = Join-Path $configDir 'settings.example.json'
    Copy-Item -Path (Join-Path $repoRoot 'config/settings.example.json') -Destination $configPath -Force
    $baseline = Join-Path $repoRoot 'config/hardening-baseline.json'
    if (Test-Path -Path $baseline) {
        Copy-Item -Path $baseline -Destination (Join-Path $configDir 'hardening-baseline.json') -Force
    }

    $env:FAKEVI_STATE = $statePath
    $env:FAKEVI_NOW = '2014-03-15T02:00:00'
    $env:VA_POWERCLI_MODULE = Join-Path $repoRoot 'simulator/FakePowerCLI/FakePowerCLI.psd1'
    $env:VA_VCENTER_PASSWORD = 'VMware1!'

    if ($Mutate) {
        $state = (Get-Content -Path $statePath) -join "`n" | ConvertFrom-Json
        & $Mutate $state
        $state | ConvertTo-Json -Depth 20 | Set-Content -Path $statePath -Encoding UTF8
    }

    $configPath
}
