function Get-AdLifecycleProtectionIssue {
    <#
    .SYNOPSIS
        Returns why an account must not be changed by a lifecycle command, or nothing.

    .DESCRIPTION
        Shared guard of the leaver and the mover. In order:

        - RID 500 (built-in Administrator) and RID 502 (krbtgt): always refused.
        - One of -CallerSid (the account running the command, or the -Credential account):
          always refused.
        - Protected accounts, refused unless -Force:
            - adminCount = 1 (is, or was, in a group protected by AdminSDHolder);
            - a member, directly or nested, of Domain Admins (RID 512), Schema Admins (518),
              Enterprise Admins (519) or BUILTIN\Administrators (S-1-5-32-544). Nested membership
              comes from the constructed tokenGroups attribute; the primaryGroupID and the
              memberOf DNs of those well-known groups are checked as well.

        The user object must carry SID, PrimaryGroupID, adminCount and tokenGroups. memberOf is
        optional: DNs with the default names and locations of those groups are also matched, as a
        fallback when tokenGroups is not returned.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$User,

        [AllowEmptyCollection()]
        [string[]]$CallerSid = @(),

        [switch]$Force
    )

    $userSid = [string]$User.SID
    $rid = $userSid.Substring($userSid.LastIndexOf('-') + 1)
    if ($rid -eq '500') {
        return 'it is the built-in Administrator account (RID 500)'
    }
    if ($rid -eq '502') {
        return 'it is the krbtgt account (RID 502)'
    }
    if ($userSid -and ($CallerSid | Where-Object { $_ -and $_ -eq $userSid })) {
        return 'it is the account running this command'
    }
    if ($Force) {
        return
    }

    if ([string]$User.adminCount -eq '1') {
        return 'adminCount is 1 (it is, or was, in a protected group such as Domain Admins); review it and use -Force to change it anyway'
    }

    $privilegedRids = @{ '512' = 'Domain Admins'; '518' = 'Schema Admins'; '519' = 'Enterprise Admins' }
    $found = [System.Collections.Generic.List[string]]::new()
    if ($User.PrimaryGroupID -and $privilegedRids.ContainsKey([string]$User.PrimaryGroupID)) {
        $found.Add($privilegedRids[[string]$User.PrimaryGroupID])
    }
    foreach ($sid in @($User.tokenGroups)) {
        $value = [string]$sid
        if ($value -eq 'S-1-5-32-544') {
            $found.Add('Administrators')
        } elseif ($value -match '^S-1-5-21-\d+-\d+-\d+-(\d+)$' -and $privilegedRids.ContainsKey($Matches[1])) {
            $found.Add($privilegedRids[$Matches[1]])
        }
    }
    # Default names of the same groups, in case tokenGroups was not returned.
    foreach ($dn in @($User.MemberOf)) {
        if ([string]$dn -match '^CN=(Domain Admins|Schema Admins|Enterprise Admins|Administrators),CN=(Users|Builtin),') {
            $found.Add($Matches[1])
        }
    }
    if ($found.Count -gt 0) {
        $names = @($found | Select-Object -Unique) -join ', '
        return ('it is a member of {0}; review it and use -Force to change it anyway' -f $names)
    }
}
