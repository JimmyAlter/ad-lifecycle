function Get-AdStaleComputer {
    <#
    .SYNOPSIS
        Lists computer accounts that have not logged on to the domain for a number of days.

    .DESCRIPTION
        Read-only. Uses the replicated lastLogonTimestamp attribute, converted from its Windows
        FILETIME value (100 ns ticks since 1601-01-01 UTC) with DateTime.FromFileTimeUtc.

        - A computer is stale when its last logon is older than -Days.
        - A computer that never logged on (attribute missing or 0) is reported only when it was
          created before the cutoff, so accounts pre-staged yesterday do not show up. These rows
          have NeverLoggedOn = $true and no DaysInactive.

        lastLogonTimestamp is only replicated every 9-14 days by default, so values of -Days below
        14 are not meaningful. Disabled computers are included; filter on Enabled if needed.

        Filtering happens in the LDAP query (so large domains do not return every computer) and
        is checked again client-side. Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER Days
        Inactivity threshold in days. Default 90.

    .PARAMETER SearchBase
        Optional OU distinguished name to limit the search to.

    .PARAMETER Server
        Optional domain controller or domain to query. When omitted, the AD module picks one.

    .PARAMETER Credential
        Account to connect to Active Directory as. Defaults to the current user.

    .EXAMPLE
        Get-AdStaleComputer -Days 120 | Sort-Object DaysInactive -Descending | Format-Table Name, LastLogonUtc, DaysInactive, OperatingSystem

        Computers inactive for more than 120 days, oldest first.

    .EXAMPLE
        Get-AdStaleComputer -SearchBase 'OU=Workstations,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' | Export-Csv .\stale-madrid.csv -NoTypeInformation

        Report for one site.

    .OUTPUTS
        AdLifecycle.StaleComputer
    #>
    [CmdletBinding()]
    [OutputType('AdLifecycle.StaleComputer')]
    param(
        [ValidateRange(1, 36500)]
        [int]$Days = 90,

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
    $ldapFilter = '(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<={0}))' -f $cutoff.ToFileTimeUtc()

    $query = @{
        LDAPFilter  = $ldapFilter
        Properties  = @('lastLogonTimestamp', 'whenCreated', 'operatingSystem')
        ErrorAction = 'Stop'
    }
    if ($SearchBase) {
        $query['SearchBase'] = $SearchBase
    }
    $connection = Get-AdLifecycleConnection -Server $Server -Credential $Credential
    foreach ($key in $connection.Keys) {
        $query[$key] = $connection[$key]
    }

    foreach ($computer in @(Get-ADComputer @query)) {
        $lastLogon = $null
        $rawValue = $computer.lastLogonTimestamp
        if ($null -ne $rawValue -and [long]$rawValue -gt 0) {
            $lastLogon = [DateTime]::FromFileTimeUtc([long]$rawValue)
        }

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

        [pscustomobject]@{
            PSTypeName        = 'AdLifecycle.StaleComputer'
            Name              = $computer.Name
            Enabled           = $computer.Enabled
            OperatingSystem   = $computer.OperatingSystem
            LastLogonUtc      = $lastLogon
            DaysInactive      = $daysInactive
            NeverLoggedOn     = ($null -eq $lastLogon)
            WhenCreatedUtc    = $created
            DistinguishedName = $computer.DistinguishedName
        }
    }
}
