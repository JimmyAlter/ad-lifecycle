function Get-AdStaleComputer {
    <#
    .SYNOPSIS
        Lists computer accounts that have not logged on or changed their password for a number of days.

    .DESCRIPTION
        Read-only. Uses two replicated attributes, both Windows FILETIME values (100 ns ticks since
        1601-01-01 UTC) converted with DateTime.FromFileTimeUtc:

        - lastLogonTimestamp: the last logon to the domain.
        - pwdLastSet: the last machine account password change. A domain member changes it every
          30 days by default, so a recent value means the machine is alive even when
          lastLogonTimestamp lags or was never written.

        By default a computer is stale only when BOTH are older than -Days. -LastLogonOnly uses
        lastLogonTimestamp alone (the 0.1.0 behaviour).

        - A computer that never logged on (lastLogonTimestamp missing or 0) is reported only when
          it was created before the cutoff, so accounts pre-staged yesterday do not show up.
          These rows have NeverLoggedOn = $true and no DaysInactive.
        - pwdLastSet = 0 ("must change password at next logon") counts as no password change.

        lastLogonTimestamp is only replicated every 9-14 days by default, so values of -Days below
        14 are not meaningful. Disabled computers are included; filter on Enabled if needed.

        Filtering happens in the LDAP query (so large domains do not return every computer) and
        is checked again client-side. Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER Days
        Inactivity threshold in days. Default 90.

    .PARAMETER LastLogonOnly
        Ignore pwdLastSet and decide on lastLogonTimestamp alone.

    .PARAMETER SearchBase
        Optional OU distinguished name to limit the search to.

    .PARAMETER Server
        Optional domain controller or domain to query. When omitted, the AD module picks one.

    .PARAMETER Credential
        Account to connect to Active Directory as. Defaults to the current user.

    .EXAMPLE
        Get-AdStaleComputer -Days 120 | Sort-Object DaysInactive -Descending | Format-Table Name, LastLogonUtc, DaysInactive, DaysSincePasswordSet, OperatingSystem

        Computers with no logon and no password change for more than 120 days, oldest first.

    .EXAMPLE
        Get-AdStaleComputer -SearchBase 'OU=Workstations,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' | Export-Csv .\stale-madrid.csv -NoTypeInformation

        Report for one site.

    .EXAMPLE
        Get-AdStaleComputer -Days 90 -LastLogonOnly

        Uses lastLogonTimestamp only, as version 0.1.0 did.

    .OUTPUTS
        AdLifecycle.StaleComputer
    #>
    [CmdletBinding()]
    [OutputType('AdLifecycle.StaleComputer')]
    param(
        [ValidateRange(1, 36500)]
        [int]$Days = 90,

        [switch]$LastLogonOnly,

        [ValidateNotNullOrEmpty()]
        [string]$SearchBase,

        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    Assert-AdModule

    $now = (Get-Date).ToUniversalTime()
    $cutoff = $now.AddDays(-$Days)
    $cutoffFileTime = $cutoff.ToFileTimeUtc()
    $ldapFilter = '(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<={0}))' -f $cutoffFileTime
    if (-not $LastLogonOnly) {
        $ldapFilter = '(&{0}(|(!(pwdLastSet=*))(pwdLastSet<={1})))' -f $ldapFilter, $cutoffFileTime
    }

    $query = @{
        LDAPFilter  = $ldapFilter
        Properties  = @('lastLogonTimestamp', 'pwdLastSet', 'whenCreated', 'operatingSystem')
        ErrorAction = 'Stop'
    }
    if ($SearchBase) {
        $query['SearchBase'] = $SearchBase
    }
    $connection = Get-AdLifecycleConnection -Server $Server -Credential $Credential
    foreach ($key in $connection.Keys) {
        $query[$key] = $connection[$key]
    }

    $fromFileTime = {
        param($Value)
        if ($null -ne $Value -and [long]$Value -gt 0) {
            [DateTime]::FromFileTimeUtc([long]$Value)
        }
    }

    foreach ($computer in @(Get-ADComputer @query)) {
        $lastLogon = & $fromFileTime $computer.lastLogonTimestamp
        $passwordSet = & $fromFileTime $computer.pwdLastSet

        $created = $null
        if ($computer.whenCreated) {
            $created = ([datetime]$computer.whenCreated).ToUniversalTime()
        }

        if ($null -ne $lastLogon) {
            if ($lastLogon -ge $cutoff) {
                continue
            }
            $daysInactive = [int][math]::Floor(($now - $lastLogon).TotalDays)
        } else {
            if ($null -ne $created -and $created -ge $cutoff) {
                continue
            }
            $daysInactive = $null
        }

        $daysSincePassword = $null
        if ($null -ne $passwordSet) {
            if (-not $LastLogonOnly -and $passwordSet -ge $cutoff) {
                continue
            }
            $daysSincePassword = [int][math]::Floor(($now - $passwordSet).TotalDays)
        }

        [pscustomobject]@{
            PSTypeName           = 'AdLifecycle.StaleComputer'
            Name                 = $computer.Name
            Enabled              = $computer.Enabled
            OperatingSystem      = $computer.OperatingSystem
            LastLogonUtc         = $lastLogon
            DaysInactive         = $daysInactive
            NeverLoggedOn        = ($null -eq $lastLogon)
            PasswordLastSetUtc   = $passwordSet
            DaysSincePasswordSet = $daysSincePassword
            WhenCreatedUtc       = $created
            DistinguishedName    = $computer.DistinguishedName
        }
    }
}
