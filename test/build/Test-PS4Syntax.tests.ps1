$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$gate = Join-Path $here '..\..\build\Test-PS4Syntax.ps1'
$gate = [System.IO.Path]::GetFullPath(($gate -replace '\\', [System.IO.Path]::DirectorySeparatorChar))

function Invoke-Gate {
    param([string[]]$Path)
    $output = & $gate -Path $Path
    New-Object PSObject -Property @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function New-SampleScript {
    param([string]$Name, [string]$Content)
    $file = Join-Path $TestDrive $Name
    Set-Content -Path $file -Value $Content
    $file
}

Describe 'Test-PS4Syntax' {

    Context 'a PowerShell 4 clean script' {
        $file = New-SampleScript -Name 'clean.ps1' -Content @'
function Get-Thing {
    [CmdletBinding()]
    param([string]$Name)
    $items = @(Get-ChildItem -Path . -Recurse)
    $o = New-Object PSObject -Property @{ Name = $Name; Count = $items.Count }
    [string]::Join(',', @('a', 'b'))
    $o
}
'@
        $result = Invoke-Gate -Path $file

        It 'exits zero' {
            $result.ExitCode | Should Be 0
        }
    }

    Context 'a class definition' {
        $file = New-SampleScript -Name 'class.ps1' -Content "`$a = 1`nclass Foo {}"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file and line' {
            $result.Output | Should Match 'class\.ps1:2:'
        }
    }

    Context 'a using statement' {
        $file = New-SampleScript -Name 'using.ps1' -Content "using namespace System`n`$a = 1"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file and line' {
            $result.Output | Should Match 'using\.ps1:1:'
        }
    }

    Context 'a ::new member invocation' {
        $file = New-SampleScript -Name 'new.ps1' -Content "`$a = 1`n`$b = 2`n`$s = [string]::new('a')"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file and line' {
            $result.Output | Should Match 'new\.ps1:3:.*::new'
        }
    }

    Context 'a banned post-PS4 cmdlet' {
        $file = New-SampleScript -Name 'cmdlet.ps1' -Content "`$a = 1`n`$f = New-TemporaryFile"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file, line and cmdlet' {
            $result.Output | Should Match 'cmdlet\.ps1:2:.*New-TemporaryFile'
        }
    }

    Context 'a syntax error' {
        $file = New-SampleScript -Name 'broken.ps1' -Content "function Broken {`n    if (`$true {`n"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file' {
            $result.Output | Should Match 'broken\.ps1:\d+:'
        }
    }

    Context 'a banned post-PS4 parameter' {
        $file = New-SampleScript -Name 'param.ps1' -Content "`$a = 1`n`$b = 2`n`$c = 3`n`$h = '{}' | ConvertFrom-Json -AsHashtable"
        $result = Invoke-Gate -Path $file

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the file, line and parameter' {
            $result.Output | Should Match 'param\.ps1:4:.*ConvertFrom-Json -AsHashtable'
        }
    }

    Context 'ConvertFrom-Json without the banned parameter' {
        $file = New-SampleScript -Name 'json.ps1' -Content "`$h = '{}' | ConvertFrom-Json"
        $result = Invoke-Gate -Path $file

        It 'exits zero' {
            $result.ExitCode | Should Be 0
        }
    }

    Context 'a path list that includes a missing path' {
        $dir = Join-Path $TestDrive 'srcdir'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'ok.ps1') -Value 'Write-Output 1'
        Set-Content -Path (Join-Path $dir 'ok.psm1') -Value 'function Get-One { 1 }'
        $missing = Join-Path $TestDrive 'does-not-exist'
        $result = Invoke-Gate -Path @($dir, $missing)

        It 'exits zero when the existing paths are clean' {
            $result.ExitCode | Should Be 0
        }
    }

    Context 'a directory holding one bad module file' {
        $dir = Join-Path $TestDrive 'baddir'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'ok.ps1') -Value 'Write-Output 1'
        Set-Content -Path (Join-Path $dir 'bad.psm1') -Value 'enum Colour { Red }'
        $result = Invoke-Gate -Path $dir

        It 'exits non-zero' {
            ($result.ExitCode -ne 0) | Should Be $true
        }
        It 'names the bad file' {
            $result.Output | Should Match 'bad\.psm1:1:'
        }
    }
}
