function Get-AdLifecycleOperator {
    <#
    .SYNOPSIS
        Returns the account running this session as DOMAIN\user (or just user off-domain).

    .DESCRIPTION
        Used in the leaver's description and CSV, and in the audit log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $operator = [Environment]::UserName
    $userDomain = [Environment]::UserDomainName
    if ($userDomain -and $userDomain -ne [Environment]::MachineName) {
        $operator = '{0}\{1}' -f $userDomain, $operator
    }
    $operator
}
