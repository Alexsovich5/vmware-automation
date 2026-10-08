@{
    RootModule        = 'FakePowerCLI.psm1'
    ModuleVersion     = '5.5.2'
    GUID              = 'b7d5f0a2-6c1e-4f3b-9a8d-2e4c71f0d915'
    Description       = 'JSON-backed simulator for the subset of PowerCLI 5.5 cmdlets used by VMwareAutomation.'
    PowerShellVersion = '4.0'
    FunctionsToExport = @(
        'Connect-VIServer',
        'Disconnect-VIServer',
        'Get-Cluster',
        'Get-VMHost',
        'Get-VM',
        'Get-Template',
        'Get-Datastore'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
