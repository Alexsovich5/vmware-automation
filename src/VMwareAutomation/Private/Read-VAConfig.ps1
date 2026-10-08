function Read-VAConfig {
    <#
    .SYNOPSIS
        Reads the JSON settings file, checks the required keys, fills defaults for optional
        settings and resolves relative paths against the config file's directory.
    .OUTPUTS
        The settings object, with logDir, outputDir and hardeningBaseline as absolute paths
        and ConfigPath set to the file that was read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw ("Config file not found: {0}" -f $Path)
    }
    $fullPath = (Resolve-Path -Path $Path).ProviderPath
    $configDir = Split-Path -Parent $fullPath

    $text = (Get-Content -Path $fullPath) -join "`n"
    $config = $null
    try {
        if ($text.Trim()) {
            $config = $text | ConvertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        throw ("Config file '{0}' is not valid JSON: {1}" -f $fullPath, $_.Exception.Message)
    }
    if (-not ($config -is [psobject]) -or -not $config.PSObject.Properties.Count) {
        throw ("Config file '{0}' is not valid JSON: expected an object with settings" -f $fullPath)
    }

    if (-not $config.PSObject.Properties['vCenter'] -or -not $config.vCenter -or
        -not $config.vCenter.PSObject.Properties['server'] -or -not $config.vCenter.server) {
        throw ("Config file '{0}' is missing required key 'vCenter.server'" -f $fullPath)
    }
    if (-not $config.PSObject.Properties['cluster'] -or -not $config.cluster) {
        throw ("Config file '{0}' is missing required key 'cluster'" -f $fullPath)
    }

    $defaultsJson = @'
{
  "vCenter":   { "user": "", "passwordEnv": "VA_VCENTER_PASSWORD" },
  "logDir":    "../logs",
  "outputDir": "../out",
  "provisioning": {
    "templates": {},
    "limits":    { "minCpu": 1, "maxCpu": 8, "minMemoryMB": 512, "maxMemoryMB": 32768 },
    "datastoreReservePct": 10,
    "hostMaxMemoryPct": 85,
    "protectedVMs": []
  },
  "capacity":    { "standardVm": { "numCpu": 2, "memoryMB": 4096, "diskGB": 40 }, "maxVcpuPerCore": 4, "haReserveHosts": 1 },
  "rightsizing": { "days": 7, "cpuLowAvgPct": 10, "cpuLowPeakPct": 30, "cpuHighAvgPct": 80, "memLowAvgPct": 20, "memHighAvgPct": 90, "minMemoryMB": 1024 },
  "loadBalance": { "thresholdPct": 20, "maxMigrations": 3, "destMaxMemoryPct": 85, "excludeVMs": [] },
  "alerts": {
    "samples": 6,
    "host":      { "cpu.usage.average": { "warn": 75, "crit": 90 }, "mem.usage.average": { "warn": 80, "crit": 95 } },
    "vm":        { "cpu.usage.average": { "warn": 85, "crit": 95 }, "mem.usage.average": { "warn": 85, "crit": 95 } },
    "datastoreFreePct": { "warn": 20, "crit": 10 },
    "smtp": { "server": "", "port": 25, "from": "vmware-automation@lab.local", "to": [] }
  },
  "snapshots": { "prefix": "auto", "staleDays": 14, "policies": [] },
  "hardeningBaseline": "./hardening-baseline.json"
}
'@
    $defaults = $defaultsJson | ConvertFrom-Json

    # Adds every default property the config lacks; recurses into objects present in both.
    $merge = {
        param($Target, $Default)
        foreach ($property in $Default.PSObject.Properties) {
            $existing = $Target.PSObject.Properties[$property.Name]
            if (-not $existing) {
                $Target | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
            }
            elseif ($property.Value -is [System.Management.Automation.PSCustomObject] -and
                    $existing.Value -is [System.Management.Automation.PSCustomObject]) {
                & $merge $existing.Value $property.Value
            }
        }
    }
    & $merge $config $defaults

    foreach ($key in @('logDir', 'outputDir', 'hardeningBaseline')) {
        $value = [string]$config.$key
        if (-not [System.IO.Path]::IsPathRooted($value)) {
            $value = Join-Path $configDir $value
        }
        $config.$key = [System.IO.Path]::GetFullPath($value)
    }

    $config | Add-Member -MemberType NoteProperty -Name 'ConfigPath' -Value $fullPath -Force
    $config
}
