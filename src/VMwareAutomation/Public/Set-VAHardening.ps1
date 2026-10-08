function Set-VAHardening {
    <#
    .SYNOPSIS
        Fixes the hardening checks that Test-VAHardening reports as non-compliant.
    .DESCRIPTION
        -Baseline defaults to the JSON file named by the config's hardeningBaseline path. Only
        non-compliant rows are touched:
        - a "value" advanced setting the entity already has (Actual is not $null) is changed with
          Set-AdvancedSetting; one it lacks is added with New-AdvancedSetting -Force;
        - a service that should be stopped is stopped with Stop-VMHostService, and a wrong startup
          policy is changed with Set-VMHostService -Policy;
        - NTP and "notValue" findings are reported only, because the baseline names neither the
          NTP servers nor the value to use instead.
        Hosts and VMs are looked up by the names in those rows with Resolve-VAExactEntity, so a
        name with wildcard characters or one shared by two objects stops the run with an error
        instead of changing an arbitrary object.
        Every change goes through ShouldProcess and calls the PowerCLI cmdlet with -Confirm:$false.
        Returns rows (EntityType, Entity, CheckId, Setting, Action) with Action Fixed, WouldFix
        under -WhatIf, or ReportOnly.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [psobject]$Baseline
    )

    if (-not $PSBoundParameters.ContainsKey('Baseline') -or -not $Baseline) {
        $Baseline = Read-VAHardeningBaseline -Config $Config
    }

    $newResult = {
        param([object]$Row, [string]$Action)
        New-Object psobject -Property ([ordered]@{
            EntityType = [string]$Row.EntityType
            Entity     = [string]$Row.Entity
            CheckId    = [string]$Row.CheckId
            Setting    = [string]$Row.Setting
            Action     = $Action
        })
    }

    $entityCache = @{}
    $getEntity = {
        param([string]$EntityType, [string]$Name)
        $key = '{0}|{1}' -f $EntityType, $Name
        if (-not $entityCache.ContainsKey($key)) {
            # Exactly one object per name: a pattern or a duplicate name must not pick an
            # arbitrary host or VM to change.
            $entityCache[$key] = Resolve-VAExactEntity -EntityType $EntityType -Name $Name
        }
        $entityCache[$key]
    }

    $rows = @(Test-VAHardening -Config $Config -Baseline $Baseline | Where-Object { $_ -and -not $_.Compliant })
    foreach ($row in $rows) {
        $section = $null
        if ($row.EntityType -eq 'VMHost') {
            $section = $Baseline.host
        }
        elseif ($row.EntityType -eq 'VM') {
            $section = $Baseline.vm
        }
        if (-not $section) {
            continue
        }

        $settingCheck = @($section.advancedSettings | Where-Object { $_ -and [string]$_.id -eq [string]$row.CheckId })
        $serviceCheck = @()
        if ($row.EntityType -eq 'VMHost') {
            $serviceCheck = @($section.services | Where-Object { $_ -and [string]$_.id -eq [string]$row.CheckId })
        }

        if ($settingCheck.Count -gt 0 -and -not $settingCheck[0].PSObject.Properties['notValue']) {
            $check = $settingCheck[0]
            $target = '{0} {1}' -f $row.EntityType, $row.Entity
            if (-not $PSCmdlet.ShouldProcess($target, ("Set {0} to {1}" -f $check.name, $check.value))) {
                Write-VALog -Config $Config -Message ('WhatIf: would set {0} on {1} to {2}' -f $check.name, $row.Entity, $check.value)
                & $newResult $row 'WouldFix'
                continue
            }
            $entity = & $getEntity ([string]$row.EntityType) ([string]$row.Entity)
            $existing = @()
            if ($null -ne $row.Actual) {
                $existing = @(Get-AdvancedSetting -Entity $entity -Name ([string]$check.name) | Where-Object { $_ })
            }
            if ($existing.Count -gt 0) {
                $null = Set-AdvancedSetting -AdvancedSetting $existing[0] -Value $check.value -Confirm:$false
            }
            else {
                $null = New-AdvancedSetting -Entity $entity -Name ([string]$check.name) -Value $check.value -Force -Confirm:$false
            }
            Write-VALog -Config $Config -Message ('Hardening: set {0} on {1} to {2}' -f $check.name, $row.Entity, $check.value)
            & $newResult $row 'Fixed'
        }
        elseif ($serviceCheck.Count -gt 0) {
            $check = $serviceCheck[0]
            $entity = & $getEntity 'VMHost' ([string]$row.Entity)
            $service = @(Get-VMHostService -VMHost $entity | Where-Object { $_ -and [string]$_.Key -eq [string]$check.key })
            if ($service.Count -eq 0) {
                Write-VALog -Config $Config -Level 'WARN' -Message ('Hardening: service {0} not found on {1}' -f $check.key, $row.Entity)
                & $newResult $row 'ReportOnly'
                continue
            }
            $stop = [bool]$service[0].Running -and -not [bool]$check.running
            $policy = [string]$check.policy
            $setPolicy = [string]$service[0].Policy -ne $policy
            if ([bool]$check.running -and -not [bool]$service[0].Running) {
                Write-VALog -Config $Config -Level 'WARN' -Message ('Hardening: {0} on {1} should be running; start it by hand' -f $check.key, $row.Entity)
            }
            $policyName = (Get-Culture).TextInfo.ToTitleCase($policy.ToLowerInvariant())
            $description = 'Stop service {0} and set its policy to {1}' -f $check.key, $policyName
            if (-not $PSCmdlet.ShouldProcess(('VMHost {0}' -f $row.Entity), $description)) {
                Write-VALog -Config $Config -Message ('WhatIf: would stop {0} on {1} and set its policy to {2}' -f $check.key, $row.Entity, $policyName)
                & $newResult $row 'WouldFix'
                continue
            }
            if ($stop) {
                $null = Stop-VMHostService -HostService $service[0] -Confirm:$false
                Write-VALog -Config $Config -Message ('Hardening: stopped {0} on {1}' -f $check.key, $row.Entity)
            }
            if ($setPolicy) {
                $null = Set-VMHostService -HostService $service[0] -Policy $policyName -Confirm:$false
                Write-VALog -Config $Config -Message ('Hardening: set {0} policy on {1} to {2}' -f $check.key, $row.Entity, $policyName)
            }
            & $newResult $row 'Fixed'
        }
        else {
            Write-VALog -Config $Config -Level 'WARN' -Message ('Hardening: {0} {1} on {2} needs a manual fix (expected {3}, actual {4})' -f $row.CheckId, $row.Setting, $row.Entity, $row.Expected, $row.Actual)
            & $newResult $row 'ReportOnly'
        }
    }
}
