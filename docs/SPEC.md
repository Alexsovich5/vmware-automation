# vmware-automation: Specification

Target period: February to May 2014. Language level: Windows PowerShell 4.0 with the VMware vSphere PowerCLI 5.5 cmdlet surface.
Scope source: the technical concept and feature list in the original README (commit `f4c4a33`). That README's role, employer and timeline lines are not carried over.

## Problem

In 2014 a small vSphere 5.5 estate (one vCenter, one or two clusters, a handful of ESXi hosts) was usually run by one administrator who did everything by hand in the vSphere Client: cloning VMs from templates, deleting old ones, taking and forgetting snapshots, moving VMs off overloaded hosts, checking performance charts, and going through the vSphere Hardening Guide one setting at a time. The job is to put that routine work into one PowerShell module built on PowerCLI 5.5. It should do the work repeatably, support `-WhatIf` wherever it changes anything, and write a single report of the estate's state.

## In scope

Features 4 (batch CSV with a result CSV) and the 0/1/2 exit codes in feature 11 are not named in the original README. They are how the README's "automated provisioning" and "monitoring and alerting" are made demonstrable and scriptable, and nothing beyond those concepts is added.

1. **vCenter connection and configuration.** Load settings from a JSON file (`ConvertFrom-Json`, PS3+), load PowerCLI the 2014 way (`Add-PSSnapin VMware.VimAutomation.Core`, with a module-path override for the simulator), and connect with `Connect-VIServer` using a password from an environment variable or a `-Credential` parameter. The helper entry point is `config/Connect-vCenter.ps1`. The loader first checks `Get-Command Get-PSSnapin -ErrorAction SilentlyContinue`, so on a host without snap-in support (pwsh) it goes straight to the module-path override instead of raising CommandNotFound.
2. **VM provisioning.** `New-VAVirtualMachine` validates a request (name, template listed in the config and free of wildcard characters, vCPU and memory limits, duplicate name), picks a host (connected, not in maintenance, lowest memory load that still fits) and a datastore (most free space above a reserve), then runs `New-VM -Template`, `Set-VM` and `Start-VM`. It supports `-WhatIf`.
3. **VM deprovisioning.** `Remove-VAVirtualMachine` refuses VMs on the protected list, powers the VM off, then runs `Remove-VM -DeletePermanently`. It supports `-WhatIf` and `-Confirm` (`ConfirmImpact='High'`). PowerCLI's `-Name` is a wildcard pattern and vCenter allows two VMs with one name, so the VM is resolved by the private helper `Resolve-VAExactEntity`: names with wildcard characters (`* ? [ ]` or the escape character) are rejected before any lookup, results are filtered to an exact (case-insensitive) name match, and exactly one VM must remain (none or several throw). The protected list is checked on the requested name and again on the resolved VM's name, and `Stop-VM`/`Remove-VM` receive the resolved object, never the name.
4. **Batch provisioning.** `Invoke-VAProvisioningBatch` and `scripts/Invoke-Provisioning.ps1` read a CSV of `Provision`/`Deprovision` rows. Each row runs independently, so one failure does not stop the batch, and the per-row results are written to a CSV. The batch passes `-Confirm:$false` to the module's mutating calls so it never prompts under `pwsh -NonInteractive`.
5. **Capacity planning.** `Get-VACapacityReport` produces per-cluster totals for CPU MHz, memory, vCPU:pCore ratio and datastore free space. Headroom is calculated after an N+1 HA reserve (the largest host is removed), and the report says how many more standard-size VMs fit.
6. **Resource optimization (recommendations).** `Find-VARightSizingCandidate` reads `Get-Stat` history (`cpu.usage.average`, `mem.usage.average`) over `rightsizing.days` and flags oversized and undersized VMs with a suggested size. Rules (VMs with no samples are skipped):
   - **Oversized CPU:** average CPU < `cpuLowAvgPct` and peak < `cpuLowPeakPct` → vCPU = max(1, ceil(NumCpu / 2)).
   - **Oversized memory:** average memory < `memLowAvgPct` → MemoryMB = max(`minMemoryMB`, MemoryMB / 2), rounded down to a multiple of 4.
   - **Undersized CPU:** average CPU > `cpuHighAvgPct` → vCPU = min(NumCpu + 1, `provisioning.limits.maxCpu`).
   - **Undersized memory:** average memory > `memHighAvgPct` → MemoryMB = min(MemoryMB × 1.5, `provisioning.limits.maxMemoryMB`), rounded down to a multiple of 4.
   - A row's `Recommendation` is `Oversized` or `Undersized` (undersized wins if both apply); unaffected dimensions keep their current value.
7. **Snapshot management and rotation.** `Invoke-VASnapshotPolicy` and `scripts/Invoke-SnapshotRotation.ps1` apply named policies from config. Each policy matches VMs by wildcard and creates `auto-<policy>-yyyyMMdd-HHmm` snapshots. It prunes auto snapshots beyond `retentionDays` or `maxSnapshots` and reports, but never deletes, manual snapshots older than `staleDays`. It returns rows with `Action` = `Created`, `Removed` or `Stale`; under `-WhatIf` the same rows come back as `WouldCreate`, `WouldRemove` or `Stale`. The health-check report does not use this function: it reads snapshot ages through the read-only private helper `Get-VASnapshotAge`. The script is meant to be run by an external scheduler.
8. **vMotion load balancing.** `Get-VALoadBalancePlan` measures host memory load only, as `MemoryUsageGB / MemoryTotalGB` from `Get-VMHost` (in the simulator this is the memory allocated to powered-on VMs; CPU load is not used). When the spread between the most and least loaded hosts is above a threshold, it builds a greedy migration plan with a cap on moves, an exclusion list and a destination headroom limit. `Invoke-VALoadBalance` and `scripts/Invoke-LoadBalance.ps1` carry out the plan with `Move-VM` and support `-WhatIf`. Before each move the VM and the destination host are resolved with `Resolve-VAExactEntity`, a VM in `loadBalance.excludeVMs` is refused (also for a plan passed in with `-Plan`), and `Move-VM` receives the resolved objects. `Set-VAHardening` resolves the hosts and VMs it changes the same way.
9. **Performance monitoring and alerting.** `Get-VAPerformanceAlert` compares the last `alerts.samples` realtime samples (`Get-Stat -Realtime -MaxSamples`) for hosts and VMs, and datastore free-space percentages, against warning and critical thresholds, and returns alert objects. Missing data is not treated as healthy: a host or powered-on VM that returns no sample for a configured metric gets an `Unknown` alert for that metric, and a cluster without hosts gets one `Unknown` alert. `Send-VAAlertMail` sends a summary with `Send-MailMessage` when SMTP is configured.
10. **Security hardening.** `Test-VAHardening` checks hosts and VMs against a JSON baseline taken from the vSphere 5.5 Hardening Guide (ESXi shell timeouts, SSH service stopped and policy off, NTP configured, persistent syslog, BPDU filter, VM isolation.tools settings, RemoteDisplay.maxConnections, tools.setInfo.sizeLimit). `Set-VAHardening` fixes the non-compliant items and supports `-WhatIf`; NTP and `notValue` findings are reported only, because the baseline names no NTP servers and no replacement value.
11. **HTML status report.** This is the trimmed version of the README's web interface. `Export-VAHtmlReport` writes one static HTML page (`ConvertTo-Html -Fragment` plus inline CSS) covering capacity, rightsizing, alerts, hardening compliance and snapshot age. `scripts/Invoke-HealthCheck.ps1` runs the checks, writes the report and exits 0 (OK), 1 (warning) or 2 (critical) in Nagios style, so a scheduler or monitor can use the result. If the check itself fails (missing config, connection error) it prints an UNKNOWN line and exits 3, so a failure is never mistaken for a warning. It also exits 3 when there is no Critical alert but at least one `Unknown` alert (precedence: Critical, then Unknown, then Warning). String cells in `alerts.csv` and in the provisioning result CSV that would start a spreadsheet formula (`= + - @`, TAB, CR) get a leading single quote (private helper `ConvertTo-VACsvSafe`), because VM and datastore names come from the inventory.
12. **Deployment helper.** `scripts/Deploy-Automation.ps1` checks the config file and baseline, copies the module into a target module directory (by default the first entry in `$env:PSModulePath`), and confirms that `Import-Module VMwareAutomation` works.

## Out of scope

| Original README item | Reason |
|---|---|
| Real vCenter Server / ESXi 5.5 connectivity | These are proprietary and need licensed Windows and ESXi hosts. Every vSphere call runs against the named simulator (see below) and has never been run against a real vCenter. |
| `Install-Module VMware.PowerCLI` (README setup step) | This is anachronistic: the PowerShell Gallery and the `VMware.PowerCLI` module arrived in 2015–2017. In 2014 PowerCLI 5.5 shipped as an MSI and was loaded with `Add-PSSnapin`, which is what the code does. |
| Scheduling through Windows Task Scheduler (the "scheduling" half of snapshot scheduling, and "Deploy automation" registering jobs) | Task Scheduler is Windows-only and cannot run in the Linux container. The scripts are schedulable entry points with exit codes, but registering them is left to the operator. |
| Interactive "web-based management interface" / "user-friendly dashboard" | A PS4-era web UI would need IIS or ASP.NET plus authentication, which is more than a solo core project needs. It is reduced to the static HTML report in feature 11. |
| Automatic resource allocation (the "Resource Optimizer" applying changes itself) | Changing vCPU or memory usually needs a power cycle and a change window. The module only recommends (feature 6) and never reconfigures VMs on its own. |
| DRS-grade load balancing (CPU load, CPU ready, affinity rules, cost/benefit) | A realistic solo core covers greedy memory-allocation spread reduction only. It does not try to rebuild DRS. |
| Real email delivery | No SMTP server is included. `Send-MailMessage` is mocked in the tests. |
| Credential storage with `Export-Clixml` (DPAPI) | DPAPI SecureString export is Windows-only and fails in the Linux container. Only an environment variable or `-Credential` is supported. |

## Architecture

```
                     config/settings.json   config/hardening-baseline.json   requests.csv
                               |                       |                         |
                               v                       v                         v
 scripts/*.ps1  ---->  VMwareAutomation module (src/VMwareAutomation)
 (entry points)         Private: Read-VAConfig, Write-VALog, Get-VANow,
                                 Import-VAPowerCLI, Test-VAVMRequest,
                                 Select-VAPlacementHost, Select-VADatastore,
                                 Get-VAStatSummary, Get-VASnapshotAge,
                                 Resolve-VAExactEntity, ConvertTo-VACsvSafe
                        Public : Connect-VAvCenter | New/Remove-VAVirtualMachine |
                                 Invoke-VAProvisioningBatch | Get-VACapacityReport |
                                 Find-VARightSizingCandidate | Invoke-VASnapshotPolicy |
                                 Get-VALoadBalancePlan | Invoke-VALoadBalance |
                                 Get-VAPerformanceAlert | Send-VAAlertMail |
                                 Test-VAHardening | Set-VAHardening | Export-VAHtmlReport
                               |
                               | PowerCLI 5.5 cmdlets (Get-VM, New-VM, Move-VM, Get-Stat, ...)
                               v
        +--------------------------------------------------+
        | real: VMware.VimAutomation.Core snap-in (Windows) |  <- not exercised
        | here: simulator/FakePowerCLI module               |  <- tests + demo
        |       state = JSON file ($env:FAKEVI_STATE)       |
        +--------------------------------------------------+
                               |
                               v
             out/report.html   out/*.csv   logs/vmware-automation.log
```

Data flow: an entry script loads the config, calls `Import-VAPowerCLI` (snap-in if `Get-PSSnapin` exists and the snap-in is registered, otherwise `$env:VA_POWERCLI_MODULE`), connects, calls public functions, writes CSV/HTML to `outputDir` and logs to `logDir`. Every change goes through `$PSCmdlet.ShouldProcess`, and entry scripts pass `-Confirm:$false` to mutating module calls so they never prompt when run non-interactively.

Clock: there is one clock source. The private helper `Get-VANow` returns `[datetime]$env:FAKEVI_NOW` when that variable is set, otherwise `Get-Date`. Every time-dependent public function (`Find-VARightSizingCandidate`, `Invoke-VASnapshotPolicy`, `Get-VAPerformanceAlert`, `Export-VAHtmlReport` for `-GeneratedAt`) uses `-Now` when given and `Get-VANow` otherwise, and every entry script accepts `-Now` and passes it through. FakePowerCLI uses the same `$env:FAKEVI_NOW` for sample timestamps and new snapshot `Created` times, so the module's query window and the simulator's samples always line up.

Design rules forced by the period tooling:
- One function per `.ps1` file. The `.psm1` dot-sources `Private\*.ps1` and `Public\*.ps1`. Pester 2.0.4 has no `Mock -ModuleName`, so unit tests dot-source the function files and the PowerCLI stubs straight into the test scope. This was the standard Pester pattern in 2014.
- Code must be PowerShell 4 syntax only: no `class`/`enum`, no `using`, no `::new()`, no cmdlets that arrived after PS4 (`Import-PowerShellDataFile`, `New-TemporaryFile`, `Expand-Archive`, `Compress-Archive`, `Write-Information`, `New-Guid`, `Format-Hex`, `Get-Clipboard`/`Set-Clipboard`, `ConvertFrom-String`), and no post-PS4 parameters on existing cmdlets (`ConvertFrom-Json -AsHashtable`, `Get-ChildItem -Depth`, `Out-File`/`Set-Content`/`Add-Content -NoNewline`, `Invoke-WebRequest`/`Invoke-RestMethod -SkipCertificateCheck`), checked through `CommandAst` parameter names. `build/Test-PS4Syntax.ps1` enforces this and skips paths that do not exist yet.

## Data model & interfaces

### Config: `config/settings.json` (example committed as `config/settings.example.json`)

```json
{
  "vCenter":   { "server": "vcsa.lab.local", "user": "administrator@vsphere.local", "passwordEnv": "VA_VCENTER_PASSWORD" },
  "cluster":   "Lab-Cluster",
  "logDir":    "../logs",
  "outputDir": "../out",
  "provisioning": {
    "templates": { "tpl-w2k12r2": { "diskGB": 40 }, "tpl-centos65": { "diskGB": 16 } },
    "limits":    { "minCpu": 1, "maxCpu": 8, "minMemoryMB": 512, "maxMemoryMB": 32768 },
    "datastoreReservePct": 10,
    "hostMaxMemoryPct": 85,
    "protectedVMs": [ "vcsa", "dc01" ]
  },
  "capacity":    { "standardVm": { "numCpu": 2, "memoryMB": 4096, "diskGB": 40 }, "maxVcpuPerCore": 4, "haReserveHosts": 1 },
  "rightsizing": { "days": 7, "cpuLowAvgPct": 10, "cpuLowPeakPct": 30, "cpuHighAvgPct": 80, "memLowAvgPct": 20, "memHighAvgPct": 90, "minMemoryMB": 1024 },
  "loadBalance": { "thresholdPct": 20, "maxMigrations": 3, "destMaxMemoryPct": 85, "excludeVMs": [ "vcsa" ] },
  "alerts": {
    "samples": 6,
    "host":      { "cpu.usage.average": { "warn": 75, "crit": 90 }, "mem.usage.average": { "warn": 80, "crit": 95 } },
    "vm":        { "cpu.usage.average": { "warn": 85, "crit": 95 }, "mem.usage.average": { "warn": 85, "crit": 95 } },
    "datastoreFreePct": { "warn": 20, "crit": 10 },
    "smtp": { "server": "", "port": 25, "from": "vmware-automation@lab.local", "to": [] }
  },
  "snapshots": {
    "prefix": "auto", "staleDays": 14,
    "policies": [ { "name": "daily", "vmNamePattern": "web-*", "retentionDays": 7, "maxSnapshots": 5, "memory": false, "quiesce": false } ]
  },
  "hardeningBaseline": "./hardening-baseline.json"
}
```

`Read-VAConfig -Path` throws a descriptive error for missing required keys (`vCenter.server`, `cluster`) and for missing or unparseable JSON. Relative paths (`logDir`, `outputDir`, `hardeningBaseline`) resolve against the config file's own directory. The example lives in `config/`, so `./hardening-baseline.json` is `config/hardening-baseline.json` and `../logs`/`../out` are `logs/` and `out/` at the repo root. Integration tests (through `New-FakeViState`) copy the config and the baseline into `$TestDrive/config/`, so `../out` and `../logs` resolve to `$TestDrive/out` and `$TestDrive/logs`. Pester 2.0.4's `$TestDrive` is a fresh `$env:TEMP/<guid>` directory, so copying the config to the `$TestDrive` root would send outputs to the shared `$env:TEMP/out` instead; the `config/` subfolder keeps every run's logs and outputs inside its own `$TestDrive` and out of the repo tree.

### Hardening baseline: `config/hardening-baseline.json`

```json
{
  "host": {
    "advancedSettings": [
      { "id": "ESXi.set-shell-interactive-timeout", "name": "UserVars.ESXiShellInteractiveTimeOut", "value": 900 },
      { "id": "ESXi.set-shell-timeout",             "name": "UserVars.ESXiShellTimeOut",            "value": 900 },
      { "id": "ESXi.config-persistent-logs",        "name": "Syslog.global.logDir",                 "notValue": "[] /scratch/log" },
      { "id": "ESXi.enable-bpdu-filter",            "name": "Net.BlockGuestBPDU",                   "value": 1 }
    ],
    "services": [ { "id": "ESXi.disable-ssh", "key": "TSM-SSH", "running": false, "policy": "off" } ],
    "ntp":      { "id": "ESXi.config-ntp", "minServers": 1 }
  },
  "vm": {
    "advancedSettings": [
      { "id": "VM.disable-console-copy",   "name": "isolation.tools.copy.disable",       "value": "TRUE" },
      { "id": "VM.disable-console-paste",  "name": "isolation.tools.paste.disable",      "value": "TRUE" },
      { "id": "VM.disable-disk-shrinking-shrink", "name": "isolation.tools.diskShrink.disable", "value": "TRUE" },
      { "id": "VM.disable-disk-shrinking-wiper",  "name": "isolation.tools.diskWiper.disable",  "value": "TRUE" },
      { "id": "VM.limit-console-connection", "name": "RemoteDisplay.maxConnections",     "value": "1" },
      { "id": "VM.limit-setinfo-size",     "name": "tools.setInfo.sizeLimit",            "value": "1048576" }
    ]
  }
}
```

### Provisioning request CSV (`config/requests.example.csv`)

```
Action,Name,Template,NumCpu,MemoryMB,Datastore,Notes
Provision,web-03,tpl-centos65,2,4096,,frontend
Deprovision,test-01,,,,,retired
```

Result CSV columns: `Action,Name,Status(Succeeded|Failed|Skipped),Host,Datastore,Message`.

### Public function signatures

```powershell
Connect-VAvCenter      -Config <psobject> [-Credential <PSCredential>]              # -> VIServer
New-VAVirtualMachine   -Config <psobject> -Name <string> -Template <string> -NumCpu <int> -MemoryMB <int>
                       [-Datastore <string>] [-Notes <string>] [-WhatIf] [-Confirm]   # -> VM object
Remove-VAVirtualMachine -Config <psobject> -Name <string> [-WhatIf] [-Confirm]
Invoke-VAProvisioningBatch -Config <psobject> -RequestPath <string> [-ResultPath <string>] [-WhatIf]  # -> result rows
Get-VACapacityReport   -Config <psobject> [-Cluster <string>]                        # -> one object per cluster
Find-VARightSizingCandidate -Config <psobject> [-Days <int>] [-Now <datetime>]      # -> recommendation rows
Invoke-VASnapshotPolicy -Config <psobject> [-PolicyName <string>] [-Now <datetime>] [-WhatIf]  # -> rows (Policy, VM, Snapshot, Action: Created|Removed|Stale; WouldCreate|WouldRemove|Stale under -WhatIf)
Get-VALoadBalancePlan  -Config <psobject> [-Cluster <string>]                        # -> ordered move rows (VM, Source, Destination, MemoryMB, SpreadBefore, SpreadAfter); spread = max - min host memory %
Invoke-VALoadBalance   -Config <psobject> [-Cluster <string>] [-WhatIf]
Get-VAPerformanceAlert -Config <psobject> [-Now <datetime>]                          # -> alert rows
Send-VAAlertMail       -Config <psobject> -Alert <psobject[]>                        # no-op when smtp.server empty
Test-VAHardening       -Config <psobject> [-Baseline <psobject>]                     # -> rows (EntityType, Entity, CheckId, Setting, Expected, Actual, Compliant)
Set-VAHardening        -Config <psobject> [-Baseline <psobject>] [-WhatIf]
Export-VAHtmlReport    -Path <string> [-Capacity ..] [-RightSizing ..] [-Alerts ..] [-Hardening ..] [-Snapshots ..] [-GeneratedAt <datetime>]

# private, read-only, used by the health check
Get-VASnapshotAge      -Config <psobject> [-Now <datetime>]                          # -> rows (VM, Snapshot, Created, AgeDays, IsAuto, Stale)
Get-VANow                                                                            # -> [datetime]$env:FAKEVI_NOW if set, else Get-Date
```

Alert row: `Severity(Warning|Critical|Unknown), EntityType(VMHost|VM|Datastore|Cluster), Entity, Metric, Value, Threshold, Timestamp`. `Unknown` rows (no samples, or no hosts with EntityType `Cluster` and Metric `hosts`) have no Value and no Threshold.
Capacity row: `Cluster, Hosts, CpuTotalMhz, CpuUsedMhz, MemoryTotalGB, MemoryUsedGB, UsableMemoryGB (after N+1), VMs, vCPUs, PCores, VcpuPerCore, DatastoreFreeGB, StandardVmsThatFit, LimitedBy(Memory|vCPU|Storage)`.
`-Now` exists on every time-dependent function and entry script so the tests stay deterministic. When it is omitted, `Get-VANow` supplies `$env:FAKEVI_NOW` or the current time (see Clock above).
Rightsizing row: `VM, NumCpu, MemoryMB, CpuAvgPct, CpuPeakPct, MemAvgPct, Recommendation(Oversized|Undersized), RecommendedNumCpu, RecommendedMemoryMB`.

### Entry scripts

```
scripts/Invoke-Provisioning.ps1     -ConfigPath <p> -RequestPath <csv> [-WhatIf]
scripts/Invoke-SnapshotRotation.ps1 -ConfigPath <p> [-PolicyName <n>] [-Now <datetime>] [-WhatIf]
scripts/Invoke-LoadBalance.ps1      -ConfigPath <p> [-Cluster <c>] [-WhatIf]
scripts/Invoke-HealthCheck.ps1      -ConfigPath <p> [-ReportPath <html>] [-Now <datetime>]   # exit 0/1/2, 3 if the check fails or data is missing
scripts/Deploy-Automation.ps1       -ConfigPath <p> [-Destination <dir>]
config/Connect-vCenter.ps1          -ConfigPath <p> [-Credential <PSCredential>]
scripts/Invoke-Demo.ps1             [-ConfigPath <p>]   # default config/settings.example.json; exit 0
```

All entry scripts pass `-Confirm:$false` to mutating module calls. `config/Connect-vCenter.ps1` calls `Get-Credential` only when neither `-Credential` nor the password environment variable is present; its test sets the environment variable, so it never prompts.

### Log format

`yyyy-MM-dd HH:mm:ss [INFO|WARN|ERROR] <function>: <message>`, appended to `<logDir>/vmware-automation.log` and echoed to `Write-Verbose`.

## Stack & pinned versions

| Component | Version | Release date | Why it was the popular choice in early 2014 |
|---|---|---|---|
| Windows PowerShell (language level) | 4.0 (WMF 4.0) | 2013-10-24 | Shipped with Windows Server 2012 R2 and was the current release throughout the period. The code uses no syntax or cmdlets newer than PS4. |
| VMware vSphere PowerCLI (cmdlet surface) | 5.5 Release 2 | 2014-03 (shipped alongside vSphere 5.5 Update 1, VMware release notes) | The current release of the official vSphere automation toolkit during the period. Its core cmdlet surface is the same as 5.5 Release 1 (2013-09). The code targets its cmdlet and parameter names, but it is simulated here, not installed. |
| VMware vSphere (simulated target) | vCenter Server / ESXi 5.5 | 2013-09-22 | The current vSphere release in the period. It is modelled by the simulator only. |
| Pester | 2.0.4 | 2014-03-09 (nuget.org publish timestamp 2014-03-09T19:22Z; pester/Pester git tag `2.0.4`) | The de facto PowerShell unit-test framework, with `Describe/It/Should Be/Mock`. 2.1.0 (nuget.org 2014-06-15) and 3.0.0 (nuget.org 2014-08-21) are after the period. |
| Ubuntu (container OS) | 14.04 LTS "Trusty" | 2014-04-17 | The base OS of the chosen image tag, released inside the period. |
| PowerShell (container runtime, anachronistic) | 6.0.4 | 2018 | See the note below. It is the oldest Linux PowerShell image still published on an Ubuntu 14.04 base. |

Pin verification: PowerShell has no manifest format that `tools/check_period.py` reads (it reads requirements.txt, package.json, composer.json, go.mod and pom.xml). A `packages.config` pinning `Pester 2.0.4` was run through the checker. It exited 0 but reported "0 checked", so the checker did not verify this pin. Pester 2.0.4's date was checked against the nuget.org registration API (published 2014-03-09T19:22:29Z) and the pester/Pester git tag, and it is before 2014-05-31. Pester is fetched at image build time from `https://github.com/pester/Pester/archive/2.0.4.zip` and checked against SHA256 `c880803480d577e1e10c899fc56e91aba361ce09c4799d355f74a319eaecbf89`, which was verified during planning.

Runtime note: Windows PowerShell 4.0 and the PowerCLI 5.5 snap-in exist only on Windows, and no Linux PowerShell existed before 2016. The only way to run and test this in Docker is a Linux PowerShell (pwsh) host. PS4 compatibility is enforced statically by `build/Test-PS4Syntax.ps1`. Pester 2.0.4 was confirmed during planning to run on `6.0.4-ubuntu-14.04`, provided `TEMP=/tmp` is set and test files are named `*.tests.ps1` in lowercase, because Pester 2.0.4's filter is case-sensitive on Linux.

## Docker images

| Image | Tag | Verified | Use |
|---|---|---|---|
| `mcr.microsoft.com/powershell` | `6.0.4-ubuntu-trusty-20180807` | HTTP 200 on `https://mcr.microsoft.com/v2/powershell/manifests/6.0.4-ubuntu-trusty-20180807`. This is the dated, non-moving form of `6.0.4-ubuntu-14.04` (also HTTP 200); both currently resolve to digest `sha256:7e430eec9dbc36aed7ceccf785525e102f9ffa6eec5039e3cd8659324e198f50`, the image in which Pester 2.0.4 was run during planning. | Base for the single `vmware-automation` image (tests and demo) |

This image is on MCR, not Docker Hub, so the Docker Hub tag API does not apply, and the MCR registry manifest endpoint was checked instead. It is amd64-only, so `docker-compose.yml` sets `platform: linux/amd64` for Apple Silicon hosts. The image has no `make`: `make` runs on the host and calls `docker compose run`.

`docker-compose.yml` uses the Compose Specification (no `version:` key). Docker Compose is post-period tooling (its predecessor fig 1.0 came out in October 2014) and is used only to build and run the container; the project code does not depend on it. It defines two services, `demo` and `tests`, without `profiles`: `docker compose up` starts only `demo` (`tests` has no default command and is only ever started with `docker compose run --rm tests ...`, which works on any defined service).

## Simulated/mocked integrations

| Real system | Replacement | Where |
|---|---|---|
| vCenter Server 5.5 + ESXi 5.5 hosts + PowerCLI 5.5 snap-in | **FakePowerCLI**: a PS4-syntax script module that implements the subset of PowerCLI 5.5 cmdlets the code calls (`Connect-VIServer`, `Disconnect-VIServer`, `Get-Cluster`, `Get-VMHost`, `Get-VM`, `Get-Template`, `Get-Datastore`, `New-VM`, `Set-VM`, `Start-VM`, `Stop-VM`, `Remove-VM`, `Move-VM`, `Get-Snapshot`, `New-Snapshot`, `Remove-Snapshot`, `Get-Stat`, `Get-AdvancedSetting`, `Set-AdvancedSetting`, `New-AdvancedSetting`, `Get-VMHostService`, `Stop-VMHostService`, `Set-VMHostService`, `Get-VMHostNtpServer`) with the same parameter names. State lives in a JSON file (`$env:FAKEVI_STATE`, seeded from `simulator/fixtures/lab-inventory.json`). Cmdlets throw PowerCLI's "not connected" error before `Connect-VIServer`. `Get-Stat` (`-Entity -Stat -Start -Finish -IntervalMins -MaxSamples -Realtime`) returns deterministic samples from the fixture, whose times are stored as minute offsets from `$env:FAKEVI_NOW`; seed snapshot times are stored as day offsets from it, and `New-Snapshot` stamps `Created` with it. Stats are fixed per fixture: moving VMs does not change host `Get-Stat` samples, only `Get-VMHost` `MemoryUsageGB`. | `simulator/FakePowerCLI/` |
| PowerCLI cmdlets in unit tests | **PowerCLI stubs + Pester 2 `Mock`**: empty functions with the PowerCLI 5.5 parameter blocks, which Pester 2's `Mock` needs before it can mock a command, each overridden per test with `Mock`. The file also stubs `Get-PSSnapin` and `Add-PSSnapin`, which do not exist in pwsh 6, so the snap-in branch of `Import-VAPowerCLI` can be mocked. | `test/stubs/PowerCLI.Stubs.ps1` |
| SMTP server | Pester `Mock Send-MailMessage` asserting the recipients, subject and body. Nothing is ever sent. | `test/unit/Send-VAAlertMail.tests.ps1` |
| Windows Task Scheduler | None. The scripts are plain entry points with exit codes. | n/a |

The final README must say that vCenter/ESXi/PowerCLI are simulated by FakePowerCLI and that the code has never been run against a real vCenter.

## Existing code inventory

`git ls-files` at HEAD returns one file:

| File | Decision | Reason |
|---|---|---|
| `README.md` | refactor | It is an honest "not implemented" placeholder. It stays until the final task regenerates it from `tools/readme_template.md` with real status and layout. |

No other code exists to reuse. Everything else is created by the implementation plan.

## Test strategy

- **Runner:** `make test` → `docker compose run --rm tests` → `pwsh -NoProfile -NonInteractive -File build/Invoke-Tests.ps1 -Path $(TEST)`. The runner:
  1. runs `build/Test-PS4Syntax.ps1` over `src/`, `scripts/`, `config/*.ps1` and `simulator/`, skipping any that do not exist yet (parse errors, `class`/`enum`/`using`/`::new`, banned post-PS4 cmdlets and banned post-PS4 parameters fail the run);
  2. fails if any file matches `*.Tests.ps1` in the wrong case, because Pester 2 would silently skip it;
  3. runs `Invoke-Pester -Path <path> -EnableExit`, so the exit code is the number of failed tests.
- **Unit tests** (`test/unit/*.tests.ps1`): each dot-sources the function under test, its private helpers and `test/stubs/PowerCLI.Stubs.ps1`, then uses `Mock` and `Assert-MockCalled`. They cover validation rules, placement choice, N+1 maths, rightsizing thresholds, snapshot retention and age maths (using `-Now`), the greedy balancing plan, alert threshold boundaries (exactly at warn or crit), hardening comparison (`value`/`notValue`/services/NTP), HTML escaping and sections, and `-WhatIf` never calling mutating cmdlets.
- **Simulator tests** (`test/simulator/*.tests.ps1`): FakePowerCLI behaves as the code expects (not-connected error, state persistence across calls, `New-VM` from template, `Move-VM` changing host load, `Get-Stat` sample windows).
- **Integration tests** (`test/integration/*.tests.ps1`): import the real module and FakePowerCLI, copy the fixture into `$TestDrive` and the config and baseline into `$TestDrive/config/` (so the config's `../out` and `../logs` resolve to `$TestDrive/out` and `$TestDrive/logs`), set `FAKEVI_STATE`, `FAKEVI_NOW`, `VA_POWERCLI_MODULE` and `VA_VCENTER_PASSWORD` (via `New-FakeViState`), and run the `scripts/*.ps1` entry points end to end, passing the returned config path as `-ConfigPath` (every entry script takes `-ConfigPath`; `scripts/Invoke-Demo.ps1` defaults it to `config/settings.example.json` and passes it to each step). They then assert on the resulting simulator state (VMs created or removed, snapshots rotated, hosts balanced, settings remediated), the output CSV and HTML, and the exit codes.
- **Pester 2.0.4 constraints:**
  - The assertions are `Be`, `BeExactly`, `BeNullOrEmpty`, `Match`, `MatchExactly`, `Exist`, `Contain`, `ContainExactly`, `Throw` and their `Not` forms, with no `BeGreaterThan`. Numeric comparisons are written as `($x -gt 5) | Should Be $true`.
  - `Contain`/`ContainExactly` test a file path's content, not collection membership. For collections use `($list -contains $x) | Should Be $true`.
  - Mock call history is cleared only at the end of each `Describe`/`Context`, not per `It`. Every `Assert-MockCalled` scenario, and especially every `-WhatIf` zero-call assertion, goes in its own `Context` block with its own `Mock` declarations.

## Known limitations that will remain

- The code has never been run against real vCenter, ESXi or PowerCLI 5.5. FakePowerCLI copies cmdlet names, parameters and object shapes for the subset used, but it does not match the real products on edge cases (task objects, `-RunAsync`, permissions, vMotion compatibility checks, storage vMotion).
- It runs on pwsh 6.0.4 on Linux, not on Windows PowerShell 4.0. PS4 compatibility is checked statically, not by running on PS4, so behavioural differences between PS4 and pwsh 6 (such as `ConvertFrom-Json` depth and some formatting) could hide bugs.
- Load balancing is a greedy heuristic on host memory allocation only (`MemoryUsageGB / MemoryTotalGB`). CPU load is not considered, and it is not DRS.
- The `Add-PSSnapin` branch of `Import-VAPowerCLI` is verified only through mocks, because pwsh has no snap-in support.
- Simulator performance stats are fixed per fixture, so migrations do not change host `Get-Stat` values, and a VM created during a run has no samples, so the health check lists it as `Unknown` (the demo's web-03).
- Rightsizing is recommendation-only.
- The HTML report is a static file, not a web application.
- There is no scheduler integration, email is never actually sent, and credentials come only from an environment variable or `-Credential`.
- Pester is fetched from a GitHub archive URL. If GitHub ever changes the archive bytes, the SHA256 check fails the image build until the hash is updated.
