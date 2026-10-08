$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '../..'))
. (Join-Path $repo 'test/TestHelpers.ps1')

$script = Join-Path $repo 'scripts/Deploy-Automation.ps1'

# Runs the entry script in its own non-interactive pwsh process.
function Invoke-DeployScript {
    param([string[]]$Argument)
    $ErrorActionPreference = 'Continue'
    $output = & pwsh -NoProfile -NonInteractive -File $script @Argument 2>&1
    New-Object psobject -Property @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

Describe 'scripts/Deploy-Automation.ps1' {

    Context 'a valid config deployed into a module directory' {
        $configPath = New-FakeViState
        $destination = Join-Path $TestDrive 'modules'
        $run = Invoke-DeployScript -Argument @('-ConfigPath', $configPath, '-Destination', $destination)
        $manifest = Join-Path $destination 'VMwareAutomation/VMwareAutomation.psd1'

        # A fresh process that only knows the deployed copy, through PSModulePath.
        $probe = '$env:PSModulePath = ''{0}''; $m = Import-Module VMwareAutomation -PassThru -ErrorAction Stop; $m.ModuleBase; @(Get-Command -Module VMwareAutomation).Count' -f $destination
        $probeOutput = @(& pwsh -NoProfile -NonInteractive -Command $probe)

        It 'exits 0' {
            $run.ExitCode | Should Be 0
        }
        It 'copies the module manifest and its function files' {
            $manifest | Should Exist
            (Join-Path $destination 'VMwareAutomation/Public/New-VAVirtualMachine.ps1') | Should Exist
            (Join-Path $destination 'VMwareAutomation/Private/Read-VAConfig.ps1') | Should Exist
        }
        It 'imports the module from the destination by name' {
            [System.IO.Path]::GetFullPath($probeOutput[0]) | Should Be ([System.IO.Path]::GetFullPath((Join-Path $destination 'VMwareAutomation')))
        }
        It 'exports all 14 public functions' {
            [int]$probeOutput[1] | Should Be 14
        }
        It 'reports the exported command count' {
            $run.Output | Should Match '14 command'
        }
    }

    Context 'a config that is not valid JSON' {
        $configPath = New-FakeViState
        Set-Content -Path $configPath -Value '{ "vCenter": ' -Encoding UTF8
        $destination = Join-Path $TestDrive 'bad-config-modules'
        $run = Invoke-DeployScript -Argument @('-ConfigPath', $configPath, '-Destination', $destination)

        It 'exits non-zero' {
            $run.ExitCode | Should Not Be 0
        }
        It 'copies nothing' {
            (Join-Path $destination 'VMwareAutomation') | Should Not Exist
        }
        It 'names the config problem' {
            $run.Output | Should Match 'not valid JSON'
        }
    }

    Context 'a config whose hardening baseline is missing' {
        $configPath = New-FakeViState
        Remove-Item -Path (Join-Path $TestDrive 'config/hardening-baseline.json')
        $destination = Join-Path $TestDrive 'no-baseline-modules'
        $run = Invoke-DeployScript -Argument @('-ConfigPath', $configPath, '-Destination', $destination)

        It 'exits non-zero' {
            $run.ExitCode | Should Not Be 0
        }
        It 'copies nothing' {
            (Join-Path $destination 'VMwareAutomation') | Should Not Exist
        }
        It 'names the missing baseline' {
            $run.Output | Should Match 'Hardening baseline file not found'
        }
    }
}
