function Invoke-VAProvisioningBatch {
    <#
    .SYNOPSIS
        Runs each Provision/Deprovision row of a request CSV and writes a result CSV.
    .DESCRIPTION
        Request columns: Action,Name,Template,NumCpu,MemoryMB,Datastore,Notes.
        Each row runs in its own try/catch, so a failing row is recorded as Failed and the
        batch carries on. Provision rows call New-VAVirtualMachine and Deprovision rows call
        Remove-VAVirtualMachine, both with -Confirm:$false. Under -WhatIf valid rows are
        recorded as Skipped and no module function is called; an unknown Action is Failed
        either way.
        Results (Action,Name,Status,Host,Datastore,Message) are returned and written with
        Export-Csv -NoTypeInformation to -ResultPath, or by default to
        <outputDir>/provisioning-yyyyMMdd-HHmm.csv.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [Parameter(Mandatory=$true)]
        [string]$RequestPath,

        [string]$ResultPath
    )

    if (-not (Test-Path -Path $RequestPath -PathType Leaf)) {
        throw ("Request file not found: {0}" -f $RequestPath)
    }
    if (-not $ResultPath) {
        $ResultPath = Join-Path $Config.outputDir ('provisioning-{0}.csv' -f (Get-VANow).ToString('yyyyMMdd-HHmm'))
    }

    $requests = @(Import-Csv -Path $RequestPath)
    Write-VALog -Config $Config -Message ("Processing {0} request(s) from {1}" -f $requests.Count, $RequestPath)

    $results = @()
    foreach ($request in $requests) {
        $action = ([string]$request.Action).Trim()
        $name = ([string]$request.Name).Trim()
        $row = New-Object psobject -Property ([ordered]@{
            Action    = $action
            Name      = $name
            Status    = 'Failed'
            Host      = ''
            Datastore = ''
            Message   = ''
        })

        try {
            if ($action -eq 'Provision') {
                $numCpu = 0
                $memoryMB = 0
                if (-not [int]::TryParse(([string]$request.NumCpu).Trim(), [ref]$numCpu)) {
                    throw ("NumCpu '{0}' is not a whole number" -f $request.NumCpu)
                }
                if (-not [int]::TryParse(([string]$request.MemoryMB).Trim(), [ref]$memoryMB)) {
                    throw ("MemoryMB '{0}' is not a whole number" -f $request.MemoryMB)
                }

                if (-not $PSCmdlet.ShouldProcess($name, 'Provision VM')) {
                    $row.Status = 'Skipped'
                    $row.Message = ("WhatIf: would provision {0} from {1}" -f $name, $request.Template)
                }
                else {
                    $arguments = @{
                        Config   = $Config
                        Name     = $name
                        Template = ([string]$request.Template).Trim()
                        NumCpu   = $numCpu
                        MemoryMB = $memoryMB
                        Notes    = [string]$request.Notes
                    }
                    $datastore = ([string]$request.Datastore).Trim()
                    if ($datastore) {
                        $arguments['Datastore'] = $datastore
                    }
                    $vm = New-VAVirtualMachine @arguments -Confirm:$false
                    $vm = @($vm)[0]
                    if ($vm -and $vm.VMHost) {
                        $row.Host = [string]$vm.VMHost.Name
                    }
                    if ($vm) {
                        $placed = @(Get-Datastore -VM $vm -ErrorAction SilentlyContinue)
                        if ($placed.Count -gt 0) {
                            $row.Datastore = [string]$placed[0].Name
                        }
                    }
                    $row.Status = 'Succeeded'
                    $row.Message = 'Provisioned'
                }
            }
            elseif ($action -eq 'Deprovision') {
                if (-not $PSCmdlet.ShouldProcess($name, 'Deprovision VM')) {
                    $row.Status = 'Skipped'
                    $row.Message = ("WhatIf: would deprovision {0}" -f $name)
                }
                else {
                    Remove-VAVirtualMachine -Config $Config -Name $name -Confirm:$false
                    $row.Status = 'Succeeded'
                    $row.Message = 'Deprovisioned'
                }
            }
            else {
                throw ("Unknown action '{0}': expected Provision or Deprovision" -f $action)
            }
        }
        catch {
            $row.Status = 'Failed'
            $row.Message = $_.Exception.Message
            Write-VALog -Config $Config -Level 'ERROR' -Message ("{0} {1} failed: {2}" -f $action, $name, $row.Message)
        }

        $results += $row
    }

    $resultDir = Split-Path -Parent $ResultPath
    if ($resultDir -and -not (Test-Path -Path $resultDir)) {
        New-Item -ItemType Directory -Path $resultDir -Force -WhatIf:$false | Out-Null
    }
    $results | Export-Csv -Path $ResultPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false

    $failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    Write-VALog -Config $Config -Message ("Batch finished: {0} row(s), {1} failed; results in {2}" -f $results.Count, $failed, $ResultPath)
    $results
}
