function Connect-VAvCenter {
    <#
    .SYNOPSIS
        Connects to the vCenter named in the config and returns the VIServer object.
    .DESCRIPTION
        Uses -Credential when given. Otherwise builds a credential from vCenter.user and the
        password held in the environment variable named by vCenter.passwordEnv, and throws
        without connecting when that variable is empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Config,

        [System.Management.Automation.PSCredential]$Credential
    )

    $server = $Config.vCenter.server

    if (-not $Credential) {
        $envName = $Config.vCenter.passwordEnv
        if (-not $envName) {
            $envName = 'VA_VCENTER_PASSWORD'
        }
        $password = [Environment]::GetEnvironmentVariable($envName)
        if (-not $password) {
            throw ("No credential for vCenter '{0}': pass -Credential or set the environment variable {1}." -f $server, $envName)
        }
        $user = $Config.vCenter.user
        if (-not $user) {
            throw ("No user for vCenter '{0}': set vCenter.user in the config or pass -Credential." -f $server)
        }
        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential($user, $secure)
    }

    Write-VALog -Config $Config -Message ("Connecting to {0} as {1}" -f $server, $Credential.UserName)
    $viServer = Connect-VIServer -Server $server -Credential $Credential -ErrorAction Stop
    Write-VALog -Config $Config -Message ("Connected to {0}" -f $server)
    $viServer
}
