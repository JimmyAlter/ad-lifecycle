function Assert-AdModule {
    <#
    .SYNOPSIS
        Fails with a clear, typed error when the ActiveDirectory module is not available.

    .DESCRIPTION
        The ActiveDirectory module is not declared in RequiredModules (that would stop this module
        from importing on machines without RSAT), so every command that talks to AD calls this
        first. The error id is 'ActiveDirectoryModuleMissing' and the category is NotInstalled.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-ADUser' -ErrorAction SilentlyContinue) {
        return
    }

    if (Get-Module -Name 'ActiveDirectory' -ListAvailable) {
        Import-Module -Name 'ActiveDirectory' -ErrorAction Stop -Verbose:$false
        return
    }

    $message = 'The ActiveDirectory PowerShell module (RSAT) is required by this command but was not found. ' +
    'Windows client: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 ' +
    '| Windows Server: Install-WindowsFeature RSAT-AD-PowerShell'
    $exception = [System.InvalidOperationException]::new($message)
    $record = [System.Management.Automation.ErrorRecord]::new(
        $exception,
        'ActiveDirectoryModuleMissing',
        [System.Management.Automation.ErrorCategory]::NotInstalled,
        'ActiveDirectory'
    )
    $PSCmdlet.ThrowTerminatingError($record)
}
