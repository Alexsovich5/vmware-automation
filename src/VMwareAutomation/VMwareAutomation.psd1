@{
    RootModule        = 'VMwareAutomation.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5d0f3c8e-2b47-4c1a-9e61-7a3f0b9c4d12'
    Description       = 'vSphere 5.5 administration tasks built on PowerCLI 5.5: provisioning, capacity, snapshots, load balancing, alerts and hardening.'
    PowerShellVersion = '4.0'
    FunctionsToExport = @('Connect-VAvCenter', 'New-VAVirtualMachine', 'Remove-VAVirtualMachine', 'Invoke-VAProvisioningBatch', 'Get-VACapacityReport', 'Find-VARightSizingCandidate', 'Invoke-VASnapshotPolicy')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
