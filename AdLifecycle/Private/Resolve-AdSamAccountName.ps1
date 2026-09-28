function Resolve-AdSamAccountName {
    <#
    .SYNOPSIS
        Returns the first sAMAccountName for a person that is not already taken.

    .DESCRIPTION
        Tries the base name from ConvertTo-AdSamAccountName, then base2, base3, ... up to MaxSuffix.
        A candidate is taken when Get-ADUser finds a user with that sAMAccountName OR with the
        matching UPN (<candidate>@<UpnSuffix>), or when it is in -Reserved (names already handed
        out earlier in the same pipeline run, which AD may not show yet).

        Candidates only ever contain a-z and 0-9, so building the LDAP filter from them is safe.
        Read-only: this runs under -WhatIf too, so the plan shows the real name.
        -Connection (Server/Credential) is passed to Get-ADUser so the check uses the same DC as
        the create.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$GivenName,

        [Parameter(Mandatory)]
        [string]$Surname,

        [Parameter(Mandatory)]
        [string]$UpnSuffix,

        [AllowEmptyCollection()]
        [string[]]$Reserved = @(),

        [ValidateRange(2, 999)]
        [int]$MaxSuffix = 99,

        # -Server / -Credential splat from Get-AdLifecycleConnection.
        [hashtable]$Connection = @{}
    )

    for ($attempt = 1; $attempt -le $MaxSuffix; $attempt++) {
        $nameParams = @{
            GivenName = $GivenName
            Surname   = $Surname
        }
        if ($attempt -ge 2) {
            $nameParams['Suffix'] = $attempt
        }
        $candidate = ConvertTo-AdSamAccountName @nameParams

        if ($Reserved -contains $candidate) {
            Write-Verbose "sAMAccountName '$candidate' was already assigned in this run; trying the next suffix."
            continue
        }

        $filter = '(|(sAMAccountName={0})(userPrincipalName={0}@{1}))' -f $candidate, $UpnSuffix
        $existing = Get-ADUser -LDAPFilter $filter -ErrorAction Stop @Connection
        if (-not $existing) {
            return $candidate
        }
        Write-Verbose "sAMAccountName '$candidate' is taken in Active Directory; trying the next suffix."
    }

    throw ("No free sAMAccountName for '{0} {1}' (tried suffixes up to {2})." -f $GivenName, $Surname, $MaxSuffix)
}
