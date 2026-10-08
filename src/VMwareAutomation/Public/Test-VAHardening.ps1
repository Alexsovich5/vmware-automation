function Test-VAHardening {
    <#
    .SYNOPSIS
        Compares the cluster's hosts and VMs with the hardening baseline.
    .DESCRIPTION
        -Baseline defaults to the JSON file named by the config's hardeningBaseline path.
        For each host in the config's cluster it checks host.advancedSettings (Get-AdvancedSetting),
        host.services (Get-VMHostService: running state and startup policy) and host.ntp
        (Get-VMHostNtpServer: at least minServers servers). For each VM in the cluster it checks
        vm.advancedSettings. A "value" check passes when the setting's value equals the baseline
        value compared as strings, ignoring case; a "notValue" check passes when the setting exists
        and differs from the forbidden value. A setting the entity does not have is non-compliant
        and its Actual is $null.
        Returns rows (EntityType, Entity, CheckId, Setting, Expected, Actual, Compliant), hosts first,
        each group sorted by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [psobject]$Baseline
    )

    if (-not $PSBoundParameters.ContainsKey('Baseline') -or -not $Baseline) {
        $Baseline = Read-VAHardeningBaseline -Config $Config
    }

    $newRow = {
        param([string]$EntityType, [string]$Entity, [string]$CheckId, [string]$Setting, [object]$Expected, [object]$Actual, [bool]$Compliant)
        New-Object psobject -Property ([ordered]@{
            EntityType = $EntityType
            Entity     = $Entity
            CheckId    = $CheckId
            Setting    = $Setting
            Expected   = $Expected
            Actual     = $Actual
            Compliant  = $Compliant
        })
    }

    # Rows for the advancedSettings checks of one entity.
    $checkSettings = {
        param([string]$EntityType, [object]$Entity, [object[]]$Checks)
        $checks = @($Checks | Where-Object { $null -ne $_ })
        if ($checks.Count -eq 0) {
            return
        }
        $names = @($checks | ForEach-Object { [string]$_.name })
        $current = @(Get-AdvancedSetting -Entity $Entity -Name $names)
        foreach ($check in $checks) {
            $found = @($current | Where-Object { $_ -and [string]$_.Name -eq [string]$check.name })
            $actual = $null
            if ($found.Count -gt 0 -and $null -ne $found[0].Value) {
                $actual = [string]$found[0].Value
            }
            if ($check.PSObject.Properties['notValue']) {
                $expected = 'not {0}' -f $check.notValue
                $compliant = ($null -ne $actual) -and ($actual -ne [string]$check.notValue)
            }
            else {
                $expected = [string]$check.value
                $compliant = ($null -ne $actual) -and ($actual -eq $expected)
            }
            & $newRow $EntityType ([string]$Entity.Name) ([string]$check.id) ([string]$check.name) $expected $actual $compliant
        }
    }

    $rows = @()
    $hostSection = $Baseline.host
    $vmSection = $Baseline.vm

    foreach ($vmHost in @(Get-VMHost -Location $Config.cluster | Sort-Object -Property Name)) {
        $hostName = [string]$vmHost.Name
        if ($hostSection) {
            $rows += @(& $checkSettings 'VMHost' $vmHost @($hostSection.advancedSettings))

            $serviceChecks = @($hostSection.services | Where-Object { $null -ne $_ })
            if ($serviceChecks.Count -gt 0) {
                $services = @(Get-VMHostService -VMHost $vmHost)
                foreach ($check in $serviceChecks) {
                    $expected = 'Running={0}; Policy={1}' -f [bool]$check.running, $check.policy
                    $service = @($services | Where-Object { $_ -and [string]$_.Key -eq [string]$check.key })
                    $actual = $null
                    $compliant = $false
                    if ($service.Count -gt 0) {
                        $actual = 'Running={0}; Policy={1}' -f [bool]$service[0].Running, $service[0].Policy
                        $compliant = ([bool]$service[0].Running -eq [bool]$check.running) -and
                            ([string]$service[0].Policy -eq [string]$check.policy)
                    }
                    $rows += & $newRow 'VMHost' $hostName ([string]$check.id) ([string]$check.key) $expected $actual $compliant
                }
            }

            if ($hostSection.ntp) {
                $minServers = [int]$hostSection.ntp.minServers
                if ($minServers -lt 1) {
                    $minServers = 1
                }
                $servers = @(Get-VMHostNtpServer -VMHost $vmHost | Where-Object { $_ } | ForEach-Object { [string]$_ })
                $rows += & $newRow 'VMHost' $hostName ([string]$hostSection.ntp.id) 'NtpServers' ('at least {0}' -f $minServers) ($servers -join ', ') ($servers.Count -ge $minServers)
            }
        }
    }

    if ($vmSection) {
        foreach ($vm in @(Get-VM -Location $Config.cluster | Sort-Object -Property Name)) {
            $rows += @(& $checkSettings 'VM' $vm @($vmSection.advancedSettings))
        }
    }

    $failed = @($rows | Where-Object { -not $_.Compliant })
    Write-VALog -Config $Config -Message ('Hardening: {0} checks, {1} non-compliant' -f $rows.Count, $failed.Count)
    foreach ($row in $failed) {
        Write-VALog -Config $Config -Level 'WARN' -Message ('Non-compliant {0} {1} {2} {3}: expected {4}, actual {5}' -f $row.EntityType, $row.Entity, $row.CheckId, $row.Setting, $row.Expected, $row.Actual)
    }
    $rows
}
