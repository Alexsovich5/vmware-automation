# vmware-automation: Implementation Plan

This plan implements `docs/SPEC.md` in 14 tasks. Each task is one commit and leaves `make test` green.

Conventions that apply to every task:
- PowerShell 4 syntax only. `build/Test-PS4Syntax.ps1` runs as part of `make test`.
- One function per file under `src/VMwareAutomation/{Public,Private}/`. Unit tests dot-source the files; they do not use `Import-Module`, because Pester 2.0.4 has no `-ModuleName` mocking.
- Test files are named `<Name>.tests.ps1` in lowercase, because Pester 2.0.4 discovers tests with a case-sensitive filter on Linux.
- One clock: each time-dependent function and entry script takes `-Now`; when omitted, the private `Get-VANow` returns `[datetime]$env:FAKEVI_NOW` if set, else `Get-Date`. The simulator uses the same `$env:FAKEVI_NOW`, and fixture stat and snapshot times are stored as offsets from it.
- Pester 2.0.4 clears mock call history only per `Describe`/`Context`, not per `It`. Every `Assert-MockCalled` scenario, and every `-WhatIf` zero-call assertion, goes in its own `Context` block with its own `Mock` declarations.
- For collections use `($list -contains $x) | Should Be $true`; `Should Contain` checks file content in Pester 2.
- Batch code and entry scripts pass `-Confirm:$false` to mutating module calls, because tests and the demo run under `pwsh -NonInteractive`.
- Every function that changes state declares `[CmdletBinding(SupportsShouldProcess=$true)]`, and its tests assert that `-WhatIf` calls no mutating cmdlet.
- `make test TEST=<path>` runs a subset. Plain `make test` runs the syntax gate and all of `test/`.

---

## T1: Scaffold Docker image, Makefile and Pester 2 test harness

**Goal:** `make test` runs inside the period image from the first commit.

**Files:**
- create `Dockerfile`: `FROM mcr.microsoft.com/powershell:6.0.4-ubuntu-trusty-20180807`; `ENV TEMP=/tmp`; a RUN step that uses pwsh `Invoke-WebRequest` to download `https://github.com/pester/Pester/archive/2.0.4.zip`, checks SHA256 `c880803480d577e1e10c899fc56e91aba361ce09c4799d355f74a319eaecbf89`, and extracts it to `/opt/Pester-2.0.4`; `WORKDIR /work`.
- create `docker-compose.yml` (Compose Specification, no `version:` key, no `profiles`): a `tests` service (build `.`, `platform: linux/amd64`, volume `.:/work`, env `TEMP=/tmp`), started only through `docker compose run --rm tests`.
- create `Makefile`: targets `build`, `test` (`TEST ?= test`), `shell`, `clean`.
- create `build/Invoke-Tests.ps1`: imports `/opt/Pester-2.0.4/Pester.psm1`, runs the syntax gate, rejects `*.Tests.ps1` casing, then runs `Invoke-Pester -Path $Path -EnableExit`.
- create `build/Test-PS4Syntax.ps1`: AST parse of `.ps1`/`.psm1` under the given paths, silently skipping paths that do not exist yet. It fails on parse errors, `TypeDefinitionAst`, `UsingStatementAst`, `::new` member invocations, the banned post-PS4 cmdlets listed in SPEC, and banned post-PS4 parameters checked through `CommandAst` parameter names (`ConvertFrom-Json -AsHashtable`, `Get-ChildItem -Depth`, `Out-File`/`Set-Content`/`Add-Content -NoNewline`, `Invoke-WebRequest`/`Invoke-RestMethod -SkipCertificateCheck`). It prints `file:line: reason` and exits non-zero.
- create `test/build/Test-PS4Syntax.tests.ps1`, `.gitignore` (`out/`, `logs/`, `config/settings.json`).

**Tests to write first:** `test/build/Test-PS4Syntax.tests.ps1` writes sample scripts into `$TestDrive` and checks that:
- a PS4-clean script passes;
- `class Foo {}`, `using namespace System`, `[string]::new('a')` and `New-TemporaryFile` each fail and name the line;
- a file with a syntax error fails;
- `ConvertFrom-Json -AsHashtable` fails as a banned parameter and names the line;
- a list of paths including one that does not exist passes when the existing paths are clean.

**Acceptance:** `make test`

**Commit message:**
```
Add Docker test harness with Pester 2.0.4 and PS4 syntax gate

Builds a PowerShell image with Pester 2.0.4 and runs all *.tests.ps1
files through make test, after a static check that code stays within
PowerShell 4 syntax and cmdlets.
```

---

## T2: Add module skeleton, JSON config loader and logging

**Goal:** add an importable `VMwareAutomation` module with config and log helpers.

**Files:**
- create `src/VMwareAutomation/VMwareAutomation.psd1` (`PowerShellVersion='4.0'`, `FunctionsToExport` list) and `VMwareAutomation.psm1` (dot-sources `Private\*.ps1` and `Public\*.ps1`).
- create `src/VMwareAutomation/Private/Read-VAConfig.ps1` (`ConvertFrom-Json`, required keys, relative paths resolved against the config directory, defaults for optional sections).
- create `src/VMwareAutomation/Private/Write-VALog.ps1`.
- create `src/VMwareAutomation/Private/Get-VANow.ps1`.
- create `config/settings.example.json` (the full schema from SPEC, with `"logDir": "../logs"`, `"outputDir": "../out"`, `"hardeningBaseline": "./hardening-baseline.json"`).
- create `test/unit/Read-VAConfig.tests.ps1`, `test/unit/Write-VALog.tests.ps1`, `test/unit/Get-VANow.tests.ps1`, `test/unit/Module.tests.ps1`.

**Tests to write first:**
- The example config loads.
- A missing `vCenter.server` throws a message naming the key.
- Invalid JSON throws a message naming the file.
- `logDir` resolves relative to the config file (for the example: `<repo>/logs`).
- `hardeningBaseline` resolves to `<config dir>/hardening-baseline.json` (a config copied into `$TestDrive/config/` with a dummy baseline next to it resolves to an existing path; the real baseline file arrives in T11, whose test asserts the example's resolved path exists).
- `Get-VANow` returns `$env:FAKEVI_NOW` when set and a current time when unset.
- A log line matches `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] `.
- `Import-Module` of the psd1 exports exactly the manifest's function list (empty for now).

**Acceptance:** `make test`

**Commit message:**
```
Add VMwareAutomation module skeleton with config loader and logging

Settings are read from a JSON file with required-key validation, and
log lines are appended to a file in the configured log directory.
```

---

## T3: Add FakePowerCLI simulator and PowerCLI stubs

**Goal:** add a stateful vSphere 5.5 simulator for integration tests and parameter-accurate stubs for unit tests.

**Files:**
- create `simulator/FakePowerCLI/FakePowerCLI.psd1`, `FakePowerCLI.psm1`, with:
  - state load/save against `$env:FAKEVI_STATE`;
  - `Connect-VIServer`/`Disconnect-VIServer` (checking credentials from the fixture and setting `$global:DefaultVIServer`);
  - `Get-Cluster`, `Get-VMHost` (with `-Location`/`-Name`, and computed `CpuUsageMhz`, `CpuTotalMhz`, `MemoryUsageGB`, `MemoryTotalGB`, `NumCpu`, `ConnectionState`), `Get-VM` (with `-Name`/`-Location`), `Get-Template`, `Get-Datastore` (with `-VMHost`).
- create `simulator/fixtures/lab-inventory.json` with exactly these entities (later tasks add snapshots, stats and settings to them but do not rename them):
  - credentials: `administrator@vsphere.local` / `VMware1!`; vCenter `vcsa.lab.local`; datacenter `Lab-DC`; cluster `Lab-Cluster`.
  - hosts (all `Connected`, none in maintenance, 2600 MHz cores):

    | Host | Cores | Memory | Powered-on VMs | Allocated | Load |
    |---|---|---|---|---|---|
    | `esx01.lab.local` | 12 | 64 GB (65536 MB) | `dc01` 1/4096, `web-01` 2/4096, `test-01` 1/2048 | 10240 MB | 15.625% |
    | `esx02.lab.local` | 12 | 64 GB (65536 MB) | `vcsa` 2/8192, `web-02` 2/4096, `app-idle01` 4/16384 | 28672 MB | 43.75% |
    | `esx03.lab.local` (overloaded, largest) | 16 | 96 GB (98304 MB) | `db01` 4/32768, `app01` 4/16384, `rpt01` 2/12288, `app-busy01` 1/8192, `app03` 2/8192, `build01` 2/8192 | 86016 MB | 87.5% |

    Plus `old-01` (2 vCPU/8192 MB, powered off) on `esx03`. VM columns are vCPU/MemoryMB. Protected VMs are `vcsa` and `dc01`.
  - templates: `tpl-centos65` and `tpl-w2k12r2` (matching `settings.example.json`).
  - datastores: `ds-ssd01` (500 GB, 180 GB free) and `ds-sata01` (2000 GB, 700 GB free) mounted on all hosts; `ds-sata02` (1000 GB, 150 GB free = 15%, the warning datastore) mounted on `esx03` only.
- create `test/stubs/PowerCLI.Stubs.ps1`: empty functions with PowerCLI 5.5 parameter names for every cmdlet listed in SPEC, plus `Get-PSSnapin` (`-Name -Registered`) and `Add-PSSnapin` (`-Name`), defined only when those commands do not already exist.
- create `test/TestHelpers.ps1`: `New-FakeViState` copies the fixture into `$TestDrive`, and `config/settings.example.json` (and the baseline once it exists) into `$TestDrive/config/`, so the config's `../out` and `../logs` resolve to `$TestDrive/out` and `$TestDrive/logs` (Pester 2.0.4's `$TestDrive` is `$env:TEMP/<guid>`, so a config at the `$TestDrive` root would write to the shared `$env:TEMP/out`). It sets `FAKEVI_STATE` (the copied state), `FAKEVI_NOW` (`2014-03-15T02:00:00`), `VA_POWERCLI_MODULE` (the FakePowerCLI psd1) and `VA_VCENTER_PASSWORD` (`VMware1!`). It returns the copied config path. A `-Mutate { param($state) ... }` scriptblock lets a test edit the copied state (for example remove stats) before use.
- create `test/simulator/FakePowerCLI.tests.ps1` and `test/TestHelpers.tests.ps1`.

**Tests to write first:**
- Helper: the config path returned by `New-FakeViState` is `$TestDrive/config/settings.example.json`, and `Read-VAConfig` (dot-sourced from `Private/`) on it resolves `outputDir` and `logDir` to paths that start with `$TestDrive` (`$TestDrive/out`, `$TestDrive/logs`).
- Calling `Get-VM` before connecting throws `You are not currently connected to any servers`.
- Wrong credentials throw.
- `Get-VMHost -Location Lab-Cluster` returns 3 hosts.
- Host `MemoryUsageGB` equals the sum of the powered-on VMs' `MemoryMB`/1024 (`esx03`: 84 GB; `old-01` is not counted).
- `Get-Datastore -VMHost esx01.lab.local` returns only `ds-ssd01` and `ds-sata01`.
- The state file is left unchanged by read-only calls.

**Acceptance:** `make test TEST=test/simulator && make test`

**Commit message:**
```
Add FakePowerCLI simulator and PowerCLI 5.5 stubs for tests

A JSON-backed module mimics the subset of PowerCLI 5.5 inventory
cmdlets the automation uses; stubs give Pester 2 mockable signatures.
```

---

## T4: Add PowerCLI loader and vCenter connection

**Goal:** load PowerCLI and connect to vCenter the way it was done in 2014.

**Files:**
- create `src/VMwareAutomation/Private/Import-VAPowerCLI.ps1`: if `Get-Command Get-PSSnapin -ErrorAction SilentlyContinue` finds the command and `Get-PSSnapin -Registered -Name VMware.VimAutomation.Core` returns it, `Add-PSSnapin VMware.VimAutomation.Core`; otherwise `Import-Module $env:VA_POWERCLI_MODULE`; otherwise throw a clear error.
- create `src/VMwareAutomation/Public/Connect-VAvCenter.ps1`: builds a PSCredential from `-Credential` or from the env var named in `passwordEnv`, then calls `Connect-VIServer -Server -Credential`.
- create `config/Connect-vCenter.ps1`: a helper that loads the config, imports the module and connects. It calls `Get-Credential` only when neither `-Credential` nor the password env var is present.
- modify `VMwareAutomation.psd1` exports.
- create `test/unit/Connect-VAvCenter.tests.ps1`, `test/unit/Import-VAPowerCLI.tests.ps1`, `test/integration/Connect.tests.ps1`.

**Tests to write first:**
- A missing password env var and no `-Credential` throws without calling `Connect-VIServer` (`Assert-MockCalled -Times 0`).
- `-Credential` takes precedence over the env var.
- The loader throws when neither the snap-in nor the env module is available.
- (own `Context`) Snap-in registered (`Mock Get-PSSnapin` returns an object): `Add-PSSnapin` is called once and `Import-Module` is not.
- (own `Context`) Snap-in not registered (`Mock Get-PSSnapin` returns nothing): `Add-PSSnapin` is not called and `Import-Module` is called with `$env:VA_POWERCLI_MODULE`.
- Integration: `config/Connect-vCenter.ps1` against FakePowerCLI, with `VA_VCENTER_PASSWORD` set by `New-FakeViState`, runs non-interactively and sets `$global:DefaultVIServer.Name`.

**Acceptance:** `make test`

**Commit message:**
```
Add PowerCLI loader and vCenter connection helper

Loads the VMware.VimAutomation.Core snap-in when registered, or a
module path override, and connects with a credential from the
environment or the caller.
```

---

## T5: Add validated VM provisioning with host and datastore placement

**Goal:** implement SPEC feature 2.

**Files:**
- create `src/VMwareAutomation/Private/Test-VAVMRequest.ps1` (name `^[a-z0-9-]{3,15}$`, template in the catalogue, CPU and memory limits, memory a multiple of 4, duplicate name).
- create `src/VMwareAutomation/Private/Select-VAPlacementHost.ps1` (connected, not in maintenance, projected memory % ≤ `hostMaxMemoryPct`, lowest load wins, host name breaks ties).
- create `src/VMwareAutomation/Private/Select-VADatastore.ps1` (explicit datastore or most free, keeping `datastoreReservePct` after the template disk).
- create `src/VMwareAutomation/Public/New-VAVirtualMachine.ps1` (`New-VM -Name -Template -VMHost -Datastore`, `Set-VM -NumCpu -MemoryMB -Notes -Confirm:$false`, `Start-VM`).
- modify `simulator/FakePowerCLI/FakePowerCLI.psm1`: add `New-VM`, `Set-VM`, `Start-VM`.
- create `test/unit/Test-VAVMRequest.tests.ps1`, `test/unit/Select-VAPlacementHost.tests.ps1`, `test/unit/Select-VADatastore.tests.ps1`, `test/unit/New-VAVirtualMachine.tests.ps1`, `test/integration/Provision.tests.ps1`.

**Tests to write first:**
- A table of invalid requests, each with its expected message.
- The placement host skips maintenance and disconnected hosts (mocked) and the overloaded host (`esx03` in the fixture).
- Placement throws "no host has capacity" when nothing fits.
- A datastore below the reserve is rejected.
- (own `Context`) `-WhatIf` never calls `New-VM`.
- Integration: a new `tpl-centos65` VM exists in the state file, powered on, with the requested CPU and memory, on `esx01.lab.local` and `ds-sata01`.

**Acceptance:** `make test`

**Commit message:**
```
Add validated VM provisioning with host and datastore placement

Requests are checked against template and sizing limits, placed on
the least loaded host with room, and cloned, sized and powered on.
```

---

## T6: Add VM deprovisioning and CSV batch provisioning

**Goal:** implement SPEC features 3 and 4.

**Files:**
- create `src/VMwareAutomation/Public/Remove-VAVirtualMachine.ps1` (`ConfirmImpact='High'`).
- create `src/VMwareAutomation/Public/Invoke-VAProvisioningBatch.ps1` (a per-row try/catch, `Skipped` under `-WhatIf`, `-Confirm:$false` on `New-VAVirtualMachine`/`Remove-VAVirtualMachine`, `Export-Csv -NoTypeInformation` results).
- create `scripts/Invoke-Provisioning.ps1` and `config/requests.example.csv`.
- modify the simulator: add `Stop-VM`, `Remove-VM` (`-DeletePermanently`).
- create `test/unit/Remove-VAVirtualMachine.tests.ps1`, `test/unit/Invoke-VAProvisioningBatch.tests.ps1`, `test/integration/ProvisioningBatch.tests.ps1`.

**Tests to write first:**
- (own `Context`) Protected `vcsa` throws and `Remove-VM` is never called.
- (own `Context`) A powered-on VM is stopped before removal.
- (own `Context`) `-WhatIf` never calls `Stop-VM` or `Remove-VM`.
- A batch containing one invalid row still processes the other rows.
- The result CSV has the columns listed in SPEC.
- An unknown `Action` gives `Failed`.
- Integration: running the script against the example CSV adds `web-03` and removes `test-01` in the state file, and exits 0.

**Acceptance:** `make test`

**Commit message:**
```
Add VM deprovisioning and CSV-driven provisioning batches

Removal refuses protected VMs and powers off before deleting; batches
process each row independently and write a result CSV.
```

---

## T7: Add capacity report and rightsizing recommendations

**Goal:** implement SPEC features 5 and 6.

**Files:**
- create `src/VMwareAutomation/Private/Get-VAStatSummary.ps1` (average, max, sample count per entity and metric).
- create `src/VMwareAutomation/Public/Get-VACapacityReport.ps1`.
- create `src/VMwareAutomation/Public/Find-VARightSizingCandidate.ps1`.
- modify the simulator: add `Get-Stat -Entity -Stat -Start -Finish -IntervalMins -MaxSamples -Realtime`, served from fixture `stats`. Sample times are minute offsets from `$env:FAKEVI_NOW`; `-Realtime` returns the newest 20-second samples.
- modify the fixture with 7 days of historical samples (offsets 0 to -10080 minutes) for every powered-on VM: `app-idle01` (4 vCPU) idle at CPU ~3% avg / 12% peak and memory ~10% avg; `app-busy01` (1 vCPU) at CPU ~88% avg and memory ~50%; others in the normal range.
- modify `test/stubs/PowerCLI.Stubs.ps1`: `Get-Stat` gets the same parameters, including `-Realtime`.
- create `test/unit/Get-VAStatSummary.tests.ps1`, `test/unit/Get-VACapacityReport.tests.ps1`, `test/unit/Find-VARightSizingCandidate.tests.ps1`, `test/integration/Capacity.tests.ps1`.

**Tests to write first:**
- N+1 removes the largest host's memory and CPU.
- `StandardVmsThatFit` is the minimum of the memory, vCPU-ratio and storage limits, and `LimitedBy` names the binding one.
- Clusters with no hosts give zeros, not division errors.
- Rightsizing: `app-idle01` gives `Oversized`, recommended vCPU 2 and memory 8192; a 1536 MB idle VM is floored at `minMemoryMB` (1024).
- `app-busy01` is flagged `Undersized` with recommended vCPU 2 and memory unchanged.
- A VM with memory above `memHighAvgPct` gets MemoryMB × 1.5 rounded down to a multiple of 4, capped at `maxMemoryMB`; a VM at `maxCpu` stays at `maxCpu`.
- A VM with no samples is skipped.
- Integration: with `FAKEVI_NOW` set and no `-Now`, the query window matches the fixture samples and both VMs appear.

**Acceptance:** `make test`

**Commit message:**
```
Add cluster capacity report and VM rightsizing recommendations

Capacity accounts for an N+1 HA reserve and reports how many standard
VMs still fit; Get-Stat history flags over- and undersized VMs.
```

---

## T8: Add snapshot policy creation and retention pruning

**Goal:** implement SPEC feature 7.

**Files:**
- create `src/VMwareAutomation/Public/Invoke-VASnapshotPolicy.ps1` (rows `Policy, VM, Snapshot, Action`; `Created`/`Removed`/`Stale`, or `WouldCreate`/`WouldRemove`/`Stale` under `-WhatIf`).
- create `src/VMwareAutomation/Private/Get-VASnapshotAge.ps1` (read-only; rows `VM, Snapshot, Created, AgeDays, IsAuto, Stale`) for the health-check report.
- create `scripts/Invoke-SnapshotRotation.ps1` (`-Now` passed through; `-Confirm:$false` on the policy call).
- modify the simulator: add `Get-Snapshot`, `New-Snapshot` (`-Name -Description -Memory -Quiesce`; `Created` = `$env:FAKEVI_NOW`), `Remove-Snapshot -Confirm:$false`.
- modify the fixture with seed snapshots stored as day offsets from `FAKEVI_NOW`: 6 `auto-daily-*` snapshots on `web-01` at -1, -2, -4, -6, -8 and -10 days, and one manual `pre-patch` snapshot at -30 days.
- create `test/unit/Invoke-VASnapshotPolicy.tests.ps1`, `test/unit/Get-VASnapshotAge.tests.ps1`, `test/integration/SnapshotRotation.tests.ps1`.

**Tests to write first:**
- The name format is `auto-daily-20140315-0200` for a fixed `-Now`.
- Snapshots older than `retentionDays` are removed.
- When over `maxSnapshots`, the oldest are removed first.
- Manual snapshots are never removed and are reported as `Stale` after `staleDays`.
- Only VMs matching the policy wildcard are touched.
- (own `Context`) `-WhatIf` gives no `New-Snapshot` or `Remove-Snapshot` calls and returns `WouldCreate`/`WouldRemove` rows.
- `Get-VASnapshotAge` reports `pre-patch` as `Stale` with `AgeDays` 30 and calls no mutating cmdlet.
- Integration: after the script runs, `web-01` holds 5 auto snapshots (new, -1, -2, -4, -6 days), `web-02` holds 1, and `pre-patch` is still present.

**Acceptance:** `make test`

**Commit message:**
```
Add policy-driven snapshot creation and retention pruning

Named policies snapshot matching VMs with a dated prefix, prune auto
snapshots by age and count, and report stale manual snapshots.
```

---

## T9: Add vMotion load balancing plan and execution

**Goal:** implement SPEC feature 8.

**Files:**
- create `src/VMwareAutomation/Public/Get-VALoadBalancePlan.ps1`: host load is memory only, `MemoryUsageGB / MemoryTotalGB` from `Get-VMHost` (no CPU term, no `Get-Stat`). A greedy loop: while the spread (max − min host memory %) is above `thresholdPct` and the number of moves is below `maxMigrations`, take the smallest powered-on, non-excluded VM (name breaks ties) on the most-loaded host whose move to the least-loaded host lowers the spread and keeps that destination at or below `destMaxMemoryPct`.
- create `src/VMwareAutomation/Public/Invoke-VALoadBalance.ps1` (`Move-VM -VM -Destination -Confirm:$false`, logged).
- create `scripts/Invoke-LoadBalance.ps1` (`-Confirm:$false` on `Invoke-VALoadBalance`).
- modify the simulator: add `Move-VM` (changes the VM's host, so `Get-VMHost` memory usage follows; `Get-Stat` samples do not change).
- create `test/unit/Get-VALoadBalancePlan.tests.ps1`, `test/unit/Invoke-VALoadBalance.tests.ps1`, `test/integration/LoadBalance.tests.ps1`.

**Tests to write first:**
- A balanced cluster gives an empty plan.
- An overloaded host gives moves in order, with `SpreadAfter < SpreadBefore` on every move.
- The plan respects `maxMigrations` and `excludeVMs`.
- The plan never makes the destination the new hottest host above the limit.
- Powered-off VMs are ignored.
- (own `Context`) `-WhatIf` gives no `Move-VM`.
- Against the fixture numbers the plan is `app-busy01`, `app03`, `build01` from `esx03` to `esx01`, with spread 71.875 → 51.04 → 30.21 → 18.75.
- Integration: after the script runs, the host memory spread in the state file is 18.75%, below the 20% threshold.

**Acceptance:** `make test`

**Commit message:**
```
Add greedy vMotion load balancing across cluster hosts

Plans migrations from the most to least loaded hosts until memory
spread drops under a threshold, capped and honouring exclusions.
```

---

## T10: Add performance threshold alerts and alert mail

**Goal:** implement SPEC feature 9.

**Files:**
- create `src/VMwareAutomation/Public/Get-VAPerformanceAlert.ps1` (hosts and powered-on VMs over `Get-Stat -Realtime -MaxSamples <alerts.samples>`, averaged, plus datastore free %).
- create `src/VMwareAutomation/Public/Send-VAAlertMail.ps1` (a no-op when `smtp.server` is empty; plain-text body sorted Critical first).
- modify the fixture with realtime samples (minute offsets from `FAKEVI_NOW`) putting `esx03.lab.local` at critical memory (~97%) and the others below warning; `ds-sata02` (15% free) is the warning datastore.
- create `test/unit/Get-VAPerformanceAlert.tests.ps1`, `test/unit/Send-VAAlertMail.tests.ps1`, `test/integration/Alerts.tests.ps1`.

**Tests to write first:**
- A value equal to `warn` is a Warning, equal to `crit` is Critical, and just below `warn` gives no alert.
- An entity gets only its highest severity.
- A datastore at 15% free is a Warning, at 5% is Critical.
- (own `Context` each) Mail is sent once with the configured `-To`/`-From`/`-SmtpServer` (`Mock Send-MailMessage`); no call when there are no alerts; no call when there is no server.
- Integration: with `FAKEVI_NOW` set and no `-Now`, alerts include `esx03.lab.local` Critical and `ds-sata02` Warning.

**Acceptance:** `make test`

**Commit message:**
```
Add performance and datastore threshold alerts with mail summary

Recent Get-Stat samples and datastore free space are compared to
warning and critical thresholds; a summary is mailed when configured.
```

---

## T11: Add hardening baseline compliance check and remediation

**Goal:** implement SPEC feature 10.

**Files:**
- create `config/hardening-baseline.json`.
- create `src/VMwareAutomation/Public/Test-VAHardening.ps1`.
- create `src/VMwareAutomation/Public/Set-VAHardening.ps1`: `Set-AdvancedSetting` or `New-AdvancedSetting` for missing VM keys; `Stop-VMHostService` plus `Set-VMHostService -Policy Off` for SSH. NTP findings are reported only, because the baseline has no NTP server list.
- modify the simulator: add `Get-AdvancedSetting`, `Set-AdvancedSetting`, `New-AdvancedSetting`, `Get-VMHostService`, `Stop-VMHostService`, `Set-VMHostService`, `Get-VMHostNtpServer`.
- modify the fixture with mixed compliance: `esx02.lab.local` with SSH running, `esx03.lab.local` with no NTP servers, and every VM except `dc01` missing the isolation keys.
- create `test/unit/Test-VAHardening.tests.ps1`, `test/unit/Set-VAHardening.tests.ps1`, `test/integration/Hardening.tests.ps1`.

**Tests to write first:**
- `value` checks compare as strings, case-insensitively.
- `notValue` fails when the value equals the forbidden default.
- A missing VM setting is non-compliant with `Actual` null.
- A running SSH service is non-compliant.
- Zero NTP servers is non-compliant.
- Remediation calls only the non-compliant items.
- (own `Context`) `-WhatIf` gives no `Set-*`/`New-*`/`Stop-*` calls.
- The example config's resolved `hardeningBaseline` path exists, and `Test-VAHardening` without `-Baseline` loads it.
- Integration: after `Set-VAHardening`, `Test-VAHardening` shows all items compliant except NTP on `esx03.lab.local`.

**Acceptance:** `make test`

**Commit message:**
```
Add vSphere 5.5 hardening baseline check and remediation

Hosts and VMs are compared to a JSON baseline of hardening guide
settings and services; non-compliant items can be fixed with WhatIf.
```

---

## T12: Add HTML status report and health-check entry script

**Goal:** implement SPEC feature 11.

**Files:**
- create `src/VMwareAutomation/Public/Export-VAHtmlReport.ps1`: `ConvertTo-Html -Fragment` per section, inline CSS, rows coloured by severity, an "all clear" line for empty sections, and the generated timestamp.
- create `scripts/Invoke-HealthCheck.ps1`, which:
  - connects;
  - accepts `-Now` and passes it through (otherwise `Get-VANow`);
  - runs capacity, rightsizing, alerts, hardening and a snapshot-age section from `Get-VASnapshotAge` (read-only, so no "What if:" output);
  - writes `report.html` and `alerts.csv` under the config's `outputDir`;
  - calls `Send-VAAlertMail`;
  - exits 2, 1 or 0.
- create `test/unit/Export-VAHtmlReport.tests.ps1`, `test/integration/HealthCheck.tests.ps1`.

**Tests to write first:**
- The report contains an `<h2>` for each of the 5 sections.
- VM names containing `<`/`&` are HTML-escaped.
- An empty section shows "No items".
- Integration: the script against the fixture exits 2 (`esx03.lab.local` is critical) and, run with `-ConfigPath` set to the path returned by `New-FakeViState`, writes `$TestDrive/out/report.html` containing `esx03.lab.local`.
- Integration: with `New-FakeViState -Mutate` lowering `esx03`'s realtime memory samples below warning, the script exits 1 (the `ds-sata02` warning remains).
- Integration: with the host samples lowered and `ds-sata02` free space raised above 20%, the script exits 0.

**Acceptance:** `make test`

**Commit message:**
```
Add static HTML status report and health-check entry script

Combines capacity, rightsizing, alerts, hardening and snapshot age in
one HTML page and exits 0, 1 or 2 by the worst alert severity.
```

---

## T13: Add deployment helper and docker compose demo

**Goal:** implement SPEC feature 12 and make `docker compose up` show the whole system working.

**Files:**
- create `scripts/Deploy-Automation.ps1`: checks that the config and baseline load, copies `src/VMwareAutomation` to `-Destination` (default: the first `$env:PSModulePath` entry), then checks `Import-Module VMwareAutomation` and `Get-Command -Module VMwareAutomation`.
- create `scripts/Invoke-Demo.ps1`, which:
  - takes `-ConfigPath` (default `config/settings.example.json`) and passes it to every step it runs;
  - seeds the state by copying the fixture to `$env:FAKEVI_STATE` (compose sets `/tmp/fakevi-state.json`; the test's `New-FakeViState` sets a path under `$TestDrive`);
  - runs the Deploy-Automation, Provisioning (example CSV), SnapshotRotation, LoadBalance and HealthCheck steps;
  - prints a before/after summary.
- modify `docker-compose.yml`: add a `demo` service running `scripts/Invoke-Demo.ps1` with `VA_POWERCLI_MODULE`, `FAKEVI_STATE`, `FAKEVI_NOW` and `VA_VCENTER_PASSWORD` set for the simulator. No `profiles`: the `tests` service has no command of its own and exits immediately if started by `docker compose up`, which is harmless; `make test` always uses `docker compose run --rm tests ...`, and `docker compose up demo` is documented as the explicit form.
- modify `Makefile`: add a `demo` target.
- create `test/integration/Deploy-Automation.tests.ps1`, `test/integration/Demo.tests.ps1`.

**Tests to write first:**
- Deploy into `$TestDrive/modules`, then check that the module imports from there and exports all 14 public functions.
- A bad config makes the deploy exit non-zero before copying.
- The demo script, run with `-ConfigPath` set to the config path returned by `New-FakeViState`, runs to completion, exits 0 (its health check exit code is reported, not propagated), and leaves `$TestDrive/out/report.html`.

**Acceptance:** `make test && docker compose run --rm demo`

**Commit message:**
```
Add module deployment script and end-to-end compose demo

Deploy-Automation validates config and installs the module; the demo
service runs every entry script against the simulated vCenter.
```

---

## T14: Regenerate README from template with honest status

**Goal:** make the final README accurate.

**Files:**
- modify `README.md`, filled in from `tools/readme_template.md`:
  - title "VMware vSphere Infrastructure Automation";
  - a plain description;
  - "Personal project built on the 2014-era stack (PowerShell 4, PowerCLI 5.5, Pester 2.0.4)";
  - Status → Implemented: features 1–12, each tied to its function and test file;
  - Not implemented: every Out-of-scope row from SPEC;
  - an explicit statement that vCenter, ESXi and the PowerCLI snap-in are simulated by FakePowerCLI, that SMTP is mocked, and that nothing has run against a real vCenter;
  - a note that the runtime is pwsh 6.0.4 on Ubuntu 14.04 with PS4 compatibility checked statically;
  - Running it: `docker compose up` and a smoke command `docker compose run --rm demo`;
  - Built with: "Windows PowerShell 4.0 syntax, PowerCLI 5.5 cmdlet surface (simulated), Pester 2.0.4; runtime pwsh 6.0.4 on Ubuntu 14.04";
  - Tests: `make test`, plus one sentence: the tests cover every module function, the simulator and the entry scripts against FakePowerCLI, and do not cover real vCenter/ESXi, real PowerCLI or Windows PowerShell 4.0 at runtime;
  - a Layout tree generated on the host after `git add` (for example `git ls-files | sort`), not written by hand, including `test/build/Readme.tests.ps1`.
- The template's rules comment is removed. There are no employer names, dates or metrics.

**Tests to write first:** `test/build/Readme.tests.ps1` checks that:
- every path in the README Layout block exists (`Test-Path` only; the image has no git);
- the README contains "simulated" and "FakePowerCLI";
- the README contains no `{{` placeholders.

**Acceptance:** `make test TEST=test/build && make test && docker compose run --rm demo`

**Commit message:**
```
Rewrite README with implemented status and generated layout

Documents what works, what is simulated or out of scope, how to run
the demo and tests, and a file tree taken from the repository.
```
