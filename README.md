# VMware vSphere Infrastructure Automation

A PowerShell module and a set of entry scripts for routine vSphere administration through the PowerCLI cmdlet surface. It provisions and removes VMs with validated host and datastore placement, runs CSV-driven provisioning batches, reports cluster capacity after an N+1 reserve, recommends VM rightsizing from performance history, creates and prunes policy-driven snapshots, plans and runs memory-based vMotion load balancing, raises performance and datastore alerts, checks and fixes settings from a vSphere 5.5 hardening baseline, and writes one static HTML status report with Nagios-style exit codes. Every vSphere call in this repository runs against a simulator, not a real vCenter.

Personal project built on the 2014-era stack (PowerShell 4, PowerCLI 5.5, Pester 2.0.4).

## Status

**Implemented**

1. vCenter connection and configuration: JSON settings loader, PowerCLI snap-in loader with a module-path override, and `Connect-VIServer` with a password from an environment variable or `-Credential`. Code: `src/VMwareAutomation/Private/Read-VAConfig.ps1`, `src/VMwareAutomation/Private/Import-VAPowerCLI.ps1`, `src/VMwareAutomation/Public/Connect-VAvCenter.ps1`, `config/Connect-vCenter.ps1`. Tests: `test/unit/Read-VAConfig.tests.ps1`, `test/unit/Import-VAPowerCLI.tests.ps1`, `test/unit/Connect-VAvCenter.tests.ps1`, `test/integration/Connect.tests.ps1`.
2. VM provisioning with request validation, host placement and datastore placement, supporting `-WhatIf`. Code: `New-VAVirtualMachine` (`src/VMwareAutomation/Public/New-VAVirtualMachine.ps1`). Tests: `test/unit/New-VAVirtualMachine.tests.ps1`, `test/unit/Test-VAVMRequest.tests.ps1`, `test/unit/Select-VAPlacementHost.tests.ps1`, `test/unit/Select-VADatastore.tests.ps1`, `test/integration/Provision.tests.ps1`.
3. VM deprovisioning that refuses protected VMs, powers off and deletes permanently, supporting `-WhatIf` and `-Confirm`. The VM is resolved by exact name first: wildcard names are rejected and a name shared by two VMs is refused, so neither can reach a protected VM or an arbitrary match. Code: `Remove-VAVirtualMachine` (`src/VMwareAutomation/Public/Remove-VAVirtualMachine.ps1`), `src/VMwareAutomation/Private/Resolve-VAExactEntity.ps1`. Tests: `test/unit/Remove-VAVirtualMachine.tests.ps1`, `test/unit/Resolve-VAExactEntity.tests.ps1`, `test/integration/ProvisioningBatch.tests.ps1`.
4. Batch provisioning from a CSV of `Provision`/`Deprovision` rows, with independent rows and a result CSV. Code: `Invoke-VAProvisioningBatch` (`src/VMwareAutomation/Public/Invoke-VAProvisioningBatch.ps1`), `scripts/Invoke-Provisioning.ps1`. Tests: `test/unit/Invoke-VAProvisioningBatch.tests.ps1`, `test/integration/ProvisioningBatch.tests.ps1`.
5. Capacity planning: per-cluster CPU, memory, vCPU:pCore and datastore totals, headroom after an N+1 HA reserve, and how many standard-size VMs still fit. Code: `Get-VACapacityReport` (`src/VMwareAutomation/Public/Get-VACapacityReport.ps1`). Tests: `test/unit/Get-VACapacityReport.tests.ps1`, `test/integration/Capacity.tests.ps1`.
6. Rightsizing recommendations from `Get-Stat` CPU and memory history (recommendation only). Code: `Find-VARightSizingCandidate` (`src/VMwareAutomation/Public/Find-VARightSizingCandidate.ps1`), `src/VMwareAutomation/Private/Get-VAStatSummary.ps1`. Tests: `test/unit/Find-VARightSizingCandidate.tests.ps1`, `test/unit/Get-VAStatSummary.tests.ps1`.
7. Snapshot policies: wildcard-matched `auto-<policy>-yyyyMMdd-HHmm` snapshots, pruning by retention days and count, and stale manual snapshots reported but never deleted. Code: `Invoke-VASnapshotPolicy` (`src/VMwareAutomation/Public/Invoke-VASnapshotPolicy.ps1`), `src/VMwareAutomation/Private/Get-VASnapshotAge.ps1`, `scripts/Invoke-SnapshotRotation.ps1`. Tests: `test/unit/Invoke-VASnapshotPolicy.tests.ps1`, `test/unit/Get-VASnapshotAge.tests.ps1`, `test/integration/SnapshotRotation.tests.ps1`.
8. vMotion load balancing: a greedy migration plan on host memory allocation with a move cap, exclusion list and destination headroom limit, carried out with `Move-VM` on VM and host objects resolved by exact name. Code: `Get-VALoadBalancePlan`, `Invoke-VALoadBalance` (`src/VMwareAutomation/Public/`), `scripts/Invoke-LoadBalance.ps1`. Tests: `test/unit/Get-VALoadBalancePlan.tests.ps1`, `test/unit/Invoke-VALoadBalance.tests.ps1`, `test/integration/LoadBalance.tests.ps1`.
9. Performance and datastore alerts against warning and critical thresholds, with a mail summary when SMTP is configured. A host or powered-on VM without samples is reported as `Unknown`, not as healthy. Code: `Get-VAPerformanceAlert`, `Send-VAAlertMail` (`src/VMwareAutomation/Public/`). Tests: `test/unit/Get-VAPerformanceAlert.tests.ps1`, `test/unit/Send-VAAlertMail.tests.ps1`, `test/integration/Alerts.tests.ps1`.
10. Hardening baseline check and remediation for hosts and VMs from `config/hardening-baseline.json`, supporting `-WhatIf`. Code: `Test-VAHardening`, `Set-VAHardening` (`src/VMwareAutomation/Public/`), `src/VMwareAutomation/Private/Read-VAHardeningBaseline.ps1`. Tests: `test/unit/Test-VAHardening.tests.ps1`, `test/unit/Set-VAHardening.tests.ps1`, `test/integration/Hardening.tests.ps1`.
11. Static HTML status report and a health-check script that exits 0 (OK), 1 (warning), 2 (critical) or 3 (the check itself failed, or `Unknown` alerts and no critical one). `alerts.csv` and the provisioning result CSV quote cells that a spreadsheet would run as formulas. Code: `Export-VAHtmlReport` (`src/VMwareAutomation/Public/Export-VAHtmlReport.ps1`), `scripts/Invoke-HealthCheck.ps1`, `src/VMwareAutomation/Private/ConvertTo-VACsvSafe.ps1`. Tests: `test/unit/Export-VAHtmlReport.tests.ps1`, `test/unit/ConvertTo-VACsvSafe.tests.ps1`, `test/integration/HealthCheck.tests.ps1`, `test/integration/Secrets.tests.ps1` (the vCenter password never appears in output, logs or reports).
12. Deployment helper that checks the config and baseline, copies the module into a module directory and confirms it imports. Code: `scripts/Deploy-Automation.ps1`. Tests: `test/integration/Deploy-Automation.tests.ps1`.

**Not implemented / known limitations**

- Real vCenter Server / ESXi 5.5 connectivity. vCenter, ESXi and the PowerCLI 5.5 snap-in are simulated by FakePowerCLI (`simulator/FakePowerCLI/`), a script module that implements the subset of PowerCLI cmdlets the code calls against a JSON state file. Nothing in this repository has run against a real vCenter.
- `Install-Module VMware.PowerCLI`. The code loads PowerCLI with `Add-PSSnapin VMware.VimAutomation.Core`, and that branch is verified only through mocks, because pwsh has no snap-in support.
- Scheduling through Windows Task Scheduler. The scripts are schedulable entry points with exit codes; registering them is left to the operator.
- An interactive web management interface or dashboard. It is reduced to the static HTML report.
- Automatic resource allocation. Rightsizing only recommends and never reconfigures VMs.
- DRS-grade load balancing (CPU load, CPU ready, affinity rules, cost/benefit). Balancing is a greedy heuristic on host memory allocation only.
- Real email delivery. No SMTP server is included and `Send-MailMessage` is mocked in the tests.
- Credential storage with `Export-Clixml` (DPAPI). Credentials come only from an environment variable or `-Credential`.
- The runtime is pwsh 6.0.4 on Ubuntu 14.04, not Windows PowerShell 4.0. PowerShell 4 compatibility is checked statically by `build/Test-PS4Syntax.ps1`, not by running on PowerShell 4.0.
- Simulator performance stats are fixed per fixture, so migrations do not change host `Get-Stat` values, and a VM created during a run has no samples, so the health check lists it as `Unknown` (web-03 in the demo).
- The vCenter password `VMware1!` in `docker-compose.yml`, `test/TestHelpers.ps1` and `simulator/fixtures/lab-inventory.json` is the simulator's lab login and unlocks only FakePowerCLI.

## Built with

- **Windows PowerShell 4.0 syntax, PowerCLI 5.5 cmdlet surface (simulated), Pester 2.0.4; runtime pwsh 6.0.4 on Ubuntu 14.04** (`mcr.microsoft.com/powershell:6.0.4-ubuntu-trusty-20180807`)

## Running it

Everything runs in Docker images from the project's era, so nothing needs installing locally beyond Docker.

```bash
docker compose up                  # runs the demo service: every entry script against FakePowerCLI
docker compose run --rm demo       # the same demo as a one-off smoke command
```

The demo seeds the simulator from `simulator/fixtures/lab-inventory.json`, runs deployment, provisioning, snapshot rotation, load balancing and the health check, and writes `out/report.html`.

## Tests

```bash
make test                # runs the suite inside the period image
make test TEST=test/unit # runs a subset
```

The tests cover every module function, the simulator and the entry scripts against FakePowerCLI, and do not cover real vCenter/ESXi, real PowerCLI or Windows PowerShell 4.0 at runtime.

## Layout

```
.gitignore
build/Invoke-Tests.ps1
build/Test-PS4Syntax.ps1
config/Connect-vCenter.ps1
config/hardening-baseline.json
config/requests.example.csv
config/settings.example.json
docker-compose.yml
Dockerfile
docs/IMPLEMENTATION_PLAN.md
docs/SPEC.md
Makefile
README.md
scripts/Deploy-Automation.ps1
scripts/Invoke-Demo.ps1
scripts/Invoke-HealthCheck.ps1
scripts/Invoke-LoadBalance.ps1
scripts/Invoke-Provisioning.ps1
scripts/Invoke-SnapshotRotation.ps1
simulator/FakePowerCLI/FakePowerCLI.psd1
simulator/FakePowerCLI/FakePowerCLI.psm1
simulator/fixtures/lab-inventory.json
src/VMwareAutomation/Private/ConvertTo-VACsvSafe.ps1
src/VMwareAutomation/Private/Get-VANow.ps1
src/VMwareAutomation/Private/Get-VASnapshotAge.ps1
src/VMwareAutomation/Private/Get-VAStatSummary.ps1
src/VMwareAutomation/Private/Import-VAPowerCLI.ps1
src/VMwareAutomation/Private/Read-VAConfig.ps1
src/VMwareAutomation/Private/Read-VAHardeningBaseline.ps1
src/VMwareAutomation/Private/Resolve-VAExactEntity.ps1
src/VMwareAutomation/Private/Select-VADatastore.ps1
src/VMwareAutomation/Private/Select-VAPlacementHost.ps1
src/VMwareAutomation/Private/Test-VAVMRequest.ps1
src/VMwareAutomation/Private/Write-VALog.ps1
src/VMwareAutomation/Public/Connect-VAvCenter.ps1
src/VMwareAutomation/Public/Export-VAHtmlReport.ps1
src/VMwareAutomation/Public/Find-VARightSizingCandidate.ps1
src/VMwareAutomation/Public/Get-VACapacityReport.ps1
src/VMwareAutomation/Public/Get-VALoadBalancePlan.ps1
src/VMwareAutomation/Public/Get-VAPerformanceAlert.ps1
src/VMwareAutomation/Public/Invoke-VALoadBalance.ps1
src/VMwareAutomation/Public/Invoke-VAProvisioningBatch.ps1
src/VMwareAutomation/Public/Invoke-VASnapshotPolicy.ps1
src/VMwareAutomation/Public/New-VAVirtualMachine.ps1
src/VMwareAutomation/Public/Remove-VAVirtualMachine.ps1
src/VMwareAutomation/Public/Send-VAAlertMail.ps1
src/VMwareAutomation/Public/Set-VAHardening.ps1
src/VMwareAutomation/Public/Test-VAHardening.ps1
src/VMwareAutomation/VMwareAutomation.psd1
src/VMwareAutomation/VMwareAutomation.psm1
test/build/Readme.tests.ps1
test/build/Test-PS4Syntax.tests.ps1
test/integration/Alerts.tests.ps1
test/integration/Capacity.tests.ps1
test/integration/Connect.tests.ps1
test/integration/Demo.tests.ps1
test/integration/Deploy-Automation.tests.ps1
test/integration/Hardening.tests.ps1
test/integration/HealthCheck.tests.ps1
test/integration/LoadBalance.tests.ps1
test/integration/Provision.tests.ps1
test/integration/ProvisioningBatch.tests.ps1
test/integration/Secrets.tests.ps1
test/integration/SnapshotRotation.tests.ps1
test/simulator/FakePowerCLI.tests.ps1
test/stubs/PowerCLI.Stubs.ps1
test/TestHelpers.ps1
test/TestHelpers.tests.ps1
test/unit/Connect-VAvCenter.tests.ps1
test/unit/ConvertTo-VACsvSafe.tests.ps1
test/unit/Export-VAHtmlReport.tests.ps1
test/unit/Find-VARightSizingCandidate.tests.ps1
test/unit/Get-VACapacityReport.tests.ps1
test/unit/Get-VALoadBalancePlan.tests.ps1
test/unit/Get-VANow.tests.ps1
test/unit/Get-VAPerformanceAlert.tests.ps1
test/unit/Get-VASnapshotAge.tests.ps1
test/unit/Get-VAStatSummary.tests.ps1
test/unit/Import-VAPowerCLI.tests.ps1
test/unit/Invoke-VALoadBalance.tests.ps1
test/unit/Invoke-VAProvisioningBatch.tests.ps1
test/unit/Invoke-VASnapshotPolicy.tests.ps1
test/unit/Module.tests.ps1
test/unit/New-VAVirtualMachine.tests.ps1
test/unit/PowerCLI.Stubs.tests.ps1
test/unit/Read-VAConfig.tests.ps1
test/unit/Remove-VAVirtualMachine.tests.ps1
test/unit/Resolve-VAExactEntity.tests.ps1
test/unit/Select-VADatastore.tests.ps1
test/unit/Select-VAPlacementHost.tests.ps1
test/unit/Send-VAAlertMail.tests.ps1
test/unit/Set-VAHardening.tests.ps1
test/unit/Test-VAHardening.tests.ps1
test/unit/Test-VAVMRequest.tests.ps1
test/unit/Write-VALog.tests.ps1
```
