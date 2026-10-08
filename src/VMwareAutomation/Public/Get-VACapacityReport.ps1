function Get-VACapacityReport {
    <#
    .SYNOPSIS
        Reports CPU, memory, vCPU and datastore capacity per cluster, and how many more
        standard-size VMs fit after an N+1 HA reserve.
    .DESCRIPTION
        -Cluster (default: the config's cluster, wildcards allowed) selects the clusters; each
        gives one row. Only Connected hosts count. The capacity.haReserveHosts largest hosts
        (by memory, then CPU) are held back: their memory leaves UsableMemoryGB and their cores
        leave the vCPU limit. VMs, vCPUs and MemoryUsedGB cover powered-on VMs.

        StandardVmsThatFit is the smallest of three limits for capacity.standardVm:
          Memory  - (UsableMemoryGB - MemoryUsedGB) / standard memory
          vCPU    - (usable cores x capacity.maxVcpuPerCore - vCPUs) / standard vCPUs
          Storage - per datastore, free space above provisioning.datastoreReservePct of its
                    capacity divided by the standard disk, summed over the datastores
        LimitedBy names the binding limit (Memory, then vCPU, then Storage on a tie). A cluster
        with no hosts gives zeros.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [string]$Cluster
    )

    if (-not $Cluster) {
        $Cluster = $Config.cluster
    }
    $standard = $Config.capacity.standardVm
    $stdCpu = [double]$standard.numCpu
    $stdMemoryMB = [double]$standard.memoryMB
    $stdDiskGB = [double]$standard.diskGB
    $maxVcpuPerCore = [double]$Config.capacity.maxVcpuPerCore
    $reserveHosts = [int]$Config.capacity.haReserveHosts
    $reservePct = [double]$Config.provisioning.datastoreReservePct

    $round = {
        param([double]$Value)
        [double][math]::Round([decimal]$Value, 2, [System.MidpointRounding]::AwayFromZero)
    }
    $whole = {
        param([double]$Value)
        if ($Value -le 0) { return 0 }
        [int][math]::Floor($Value)
    }

    foreach ($clusterObject in @(Get-Cluster -Name $Cluster -ErrorAction Stop)) {
        $hosts = @(Get-VMHost -Location $clusterObject | Where-Object { "$($_.ConnectionState)" -eq 'Connected' })
        $vms = @(Get-VM -Location $clusterObject | Where-Object { "$($_.PowerState)" -eq 'PoweredOn' })
        $datastores = @()
        if ($hosts.Count -gt 0) {
            $datastores = @(Get-Datastore -VMHost $hosts | Sort-Object -Property Name -Unique)
        }

        $cpuTotal = 0.0
        $cpuUsed = 0.0
        $memTotalGB = 0.0
        $memUsedGB = 0.0
        $cores = 0
        foreach ($h in $hosts) {
            $cpuTotal += [double]$h.CpuTotalMhz
            $cpuUsed += [double]$h.CpuUsageMhz
            $memTotalGB += [double]$h.MemoryTotalGB
            $memUsedGB += [double]$h.MemoryUsageGB
            $cores += [int]$h.NumCpu
        }

        $reserved = @($hosts | Sort-Object -Property @{ Expression = { [double]$_.MemoryTotalGB }; Descending = $true },
            @{ Expression = { [double]$_.CpuTotalMhz }; Descending = $true } | Select-Object -First $reserveHosts)
        $usableMemGB = $memTotalGB
        $usableCores = $cores
        foreach ($h in $reserved) {
            $usableMemGB -= [double]$h.MemoryTotalGB
            $usableCores -= [int]$h.NumCpu
        }
        if ($usableMemGB -lt 0) { $usableMemGB = 0 }
        if ($usableCores -lt 0) { $usableCores = 0 }

        $vcpus = 0
        foreach ($vm in $vms) {
            $vcpus += [int]$vm.NumCpu
        }

        $freeGB = 0.0
        $storageFit = 0
        foreach ($ds in $datastores) {
            $freeGB += [double]$ds.FreeSpaceGB
            $aboveReserve = [double]$ds.FreeSpaceGB - [double]$ds.CapacityGB * $reservePct / 100
            if ($stdDiskGB -gt 0) {
                $storageFit += & $whole ($aboveReserve / $stdDiskGB)
            }
        }

        $memoryFit = 0
        if ($stdMemoryMB -gt 0) {
            $memoryFit = & $whole (($usableMemGB - $memUsedGB) * 1024 / $stdMemoryMB)
        }
        $vcpuFit = 0
        if ($stdCpu -gt 0) {
            $vcpuFit = & $whole (($usableCores * $maxVcpuPerCore - $vcpus) / $stdCpu)
        }

        $fit = $memoryFit
        $limitedBy = 'Memory'
        if ($vcpuFit -lt $fit) {
            $fit = $vcpuFit
            $limitedBy = 'vCPU'
        }
        if ($storageFit -lt $fit) {
            $fit = $storageFit
            $limitedBy = 'Storage'
        }

        $ratio = 0
        if ($cores -gt 0) {
            $ratio = & $round ($vcpus / $cores)
        }

        New-Object psobject -Property ([ordered]@{
            Cluster            = [string]$clusterObject.Name
            Hosts              = $hosts.Count
            CpuTotalMhz        = & $round $cpuTotal
            CpuUsedMhz         = & $round $cpuUsed
            MemoryTotalGB      = & $round $memTotalGB
            MemoryUsedGB       = & $round $memUsedGB
            UsableMemoryGB     = & $round $usableMemGB
            VMs                = $vms.Count
            vCPUs              = $vcpus
            PCores             = $cores
            VcpuPerCore        = $ratio
            DatastoreFreeGB    = & $round $freeGB
            StandardVmsThatFit = $fit
            LimitedBy          = $limitedBy
        })

        Write-VALog -Config $Config -Message ("{0}: {1} standard VMs fit, limited by {2}" -f $clusterObject.Name, $fit, $limitedBy)
    }
}
