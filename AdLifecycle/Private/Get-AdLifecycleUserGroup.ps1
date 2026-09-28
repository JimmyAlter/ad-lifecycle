function Get-AdLifecycleUserGroup {
    <#
    .SYNOPSIS
        Lists a user's group memberships from memberOf and primaryGroupID.

    .DESCRIPTION
        Replaces Get-ADPrincipalGroupMembership, which fails outright for users in groups that
        contain foreign security principals or members from other domains ("An unspecified error
        has occurred"). Instead:

        - the primary group is resolved from the user's SID and primaryGroupID
          (Get-ADGroup -Identity <domain SID>-<RID>); memberOf never lists it;
        - Domain Users (RID 513) is resolved the same way, so it is recognised by RID even when
          its name is localized and it is not the primary group;
        - every other group comes from the memberOf DNs of the user, named after their RDN.

        Returns one object per group: Name, DistinguishedName, IsPrimary, IsDomainUsers. The
        primary group comes first. The user object must carry SID, PrimaryGroupID and MemberOf.
        memberOf lists the groups of the user's own domain plus universal groups of the forest,
        as seen by the domain controller queried. Throws when the SID or a group cannot be resolved.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$User,

        [hashtable]$Connection = @{}
    )

    $userSid = [string]$User.SID
    if ($userSid -notmatch '^(S-1-5-21-\d+-\d+-\d+)-\d+$') {
        throw ("Unexpected SID '{0}' for '{1}'." -f $userSid, $User.DistinguishedName)
    }
    $domainSid = $Matches[1]

    $primaryRid = 513
    if ($User.PrimaryGroupID) {
        $primaryRid = [int]$User.PrimaryGroupID
    }

    # Primary group first, then Domain Users when it is not the primary group.
    $byRid = [ordered]@{}
    foreach ($rid in @($primaryRid, 513) | Select-Object -Unique) {
        $group = Get-ADGroup -Identity ('{0}-{1}' -f $domainSid, $rid) -ErrorAction Stop @Connection
        if (-not $group -or -not $group.DistinguishedName) {
            throw ('The group with RID {0} was not found.' -f $rid)
        }
        $byRid[[string]$rid] = $group
    }

    $primary = $byRid[[string]$primaryRid]
    [pscustomobject]@{
        Name              = [string]$primary.Name
        DistinguishedName = [string]$primary.DistinguishedName
        IsPrimary         = $true
        IsDomainUsers     = ($primaryRid -eq 513)
    }
    $domainUsersDn = [string]$byRid['513'].DistinguishedName

    foreach ($dn in @($User.MemberOf)) {
        if (-not $dn) {
            continue
        }
        $dn = [string]$dn
        # RDN value: everything up to the first unescaped comma, then unescape "\," "\+" etc.
        $name = $dn -replace '^[A-Za-z]+=((?:[^,\\]|\\.)+),.*$', '$1'
        $name = $name -replace '\\(.)', '$1'
        [pscustomobject]@{
            Name              = $name
            DistinguishedName = $dn
            IsPrimary         = $false
            IsDomainUsers     = ($dn -eq $domainUsersDn)
        }
    }
}
