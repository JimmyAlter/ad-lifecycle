function Resolve-AdLifecycleCredentialSid {
    <#
    .SYNOPSIS
        Returns the SID of the -Credential account, looked up in AD once per run.

    .DESCRIPTION
        With -Credential the AD calls run as that account, so the leaver must refuse to offboard
        it. The user name can be DOMAIN\name, name@upn.suffix or a bare name:

        - name@suffix: looked up by userPrincipalName; when no account has that UPN (implicit
          UPNs such as name@dns.domain are not stored), by the part before @ as sAMAccountName.
        - DOMAIN\name or name: looked up by sAMAccountName.

        Returns nothing when the connection has no credential. Throws when the account cannot be
        found, so a command never runs with an identity it could not check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [hashtable]$Connection = @{}
    )

    if (-not $Connection.ContainsKey('Credential')) {
        return
    }
    $userName = [string]$Connection['Credential'].UserName

    # RFC 4515 escaping for values placed in an LDAP filter.
    $escape = {
        param([string]$Value)
        $builder = [System.Text.StringBuilder]::new()
        foreach ($char in $Value.ToCharArray()) {
            if ($char -eq '\' -or $char -eq '*' -or $char -eq '(' -or $char -eq ')' -or [int]$char -eq 0) {
                [void]$builder.AppendFormat('\{0:x2}', [int]$char)
            } else {
                [void]$builder.Append($char)
            }
        }
        $builder.ToString()
    }

    $filters = [System.Collections.Generic.List[string]]::new()
    if ($userName -match '^([^@\\]+)@(.+)$') {
        $filters.Add(('(userPrincipalName={0})' -f (& $escape $userName)))
        $filters.Add(('(sAMAccountName={0})' -f (& $escape $Matches[1])))
    } else {
        $filters.Add(('(sAMAccountName={0})' -f (& $escape ($userName -replace '^.*\\', ''))))
    }

    $lookup = @{}
    foreach ($key in $Connection.Keys) {
        $lookup[$key] = $Connection[$key]
    }
    foreach ($filter in $filters) {
        try {
            $account = @(Get-ADUser -LDAPFilter ('(&(objectCategory=person)(objectClass=user){0})' -f $filter) -ErrorAction Stop @lookup) |
                Select-Object -First 1
        } catch {
            throw ("Could not look up the -Credential account '{0}': {1}" -f $userName, $_.Exception.Message)
        }
        if ($account -and $account.SID) {
            return [string]$account.SID
        }
    }
    throw ("The -Credential account '{0}' was not found in Active Directory." -f $userName)
}
