function Get-AdLifecycleCallerSid {
    <#
    .SYNOPSIS
        Returns the SID of the Windows account running this session, or nothing.

    .DESCRIPTION
        Used by the leaver so an operator cannot offboard their own account by mistake. Returns
        nothing where there is no Windows identity (PowerShell 7 on Linux or macOS).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity -and $identity.User) {
            return $identity.User.Value
        }
    } catch {
        Write-Verbose ('No Windows identity for this session: {0}' -f $_.Exception.Message)
    }
}
