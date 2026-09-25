function Get-AdLifecycleConfigProblem {
    <#
    .SYNOPSIS
        Returns the problems found in an AdLifecycle configuration hashtable.

    .DESCRIPTION
        Pure validation: no file I/O and no Active Directory calls. Returns one
        AdLifecycle.ConfigProblem object (Path, Setting, Message) per problem and nothing when the
        configuration is valid. Used by Get-AdLifecycleConfig, which refuses to continue on any
        problem, and by the public Test-AdLifecycleConfig.

        It checks the shape of the configuration, not that the OUs or groups exist in AD.
    #>
    [CmdletBinding()]
    [OutputType('AdLifecycle.ConfigProblem')]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config,

        [string]$Path = '(in memory)'
    )

    $knownSettings = @('UpnSuffix', 'DisabledOU', 'PasswordLength', 'Sites', 'CommonGroups', 'Departments')

    # One or more OU=/CN= components (escaped characters such as "\," allowed) followed by DC= components.
    $dnPattern = '^(?:(?:OU|CN)=(?:[^,=+<>;\\"]|\\.)+,)+DC=[A-Za-z0-9-]+(?:,DC=[A-Za-z0-9-]+)*$'
    $dnsLabel = '[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    $dnsSuffixPattern = '^{0}(?:\.{0})+$' -f $dnsLabel

    $source = $Path
    $problems = [System.Collections.Generic.List[object]]::new()
    $report = {
        param([string]$Setting, [string]$Message)
        $problem = [pscustomobject]@{
            PSTypeName = 'AdLifecycle.ConfigProblem'
            Path       = $source
            Setting    = $Setting
            Message    = $Message
        }
        $problems.Add($problem)
    }

    $testGroupList = {
        param([string]$Setting, [object]$Value, [bool]$AllowEmpty)
        if ($null -eq $Value) {
            if (-not $AllowEmpty) {
                & $report $Setting 'Has no groups. Every department needs at least one group.'
            }
            return
        }
        $items = @($Value)
        if ($items.Count -eq 0 -and -not $AllowEmpty) {
            & $report $Setting 'Has no groups. Every department needs at least one group.'
            return
        }
        foreach ($item in $items) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
                & $report $Setting 'Must be a list of group names (non-empty strings).'
                return
            }
        }
    }

    if ($Config -isnot [System.Collections.IDictionary]) {
        & $report '(root)' 'The configuration must be a hashtable: @{ ... }.'
        return $problems
    }

    foreach ($key in @($Config.Keys)) {
        if ($knownSettings -notcontains $key) {
            & $report ([string]$key) ('Unknown setting. Valid settings are: {0}.' -f ($knownSettings -join ', '))
        }
    }

    $upnSuffix = $Config['UpnSuffix']
    if ([string]::IsNullOrWhiteSpace([string]$upnSuffix)) {
        & $report 'UpnSuffix' 'Required. The UPN suffix for new accounts, for example corp.example.'
    } elseif ($upnSuffix -isnot [string] -or $upnSuffix -notmatch $dnsSuffixPattern) {
        & $report 'UpnSuffix' ("'{0}' is not a valid DNS suffix." -f $upnSuffix)
    }

    $disabledOu = $Config['DisabledOU']
    if ([string]::IsNullOrWhiteSpace([string]$disabledOu)) {
        & $report 'DisabledOU' 'Required. The OU that leavers are moved to.'
    } elseif ($disabledOu -isnot [string] -or $disabledOu -notmatch $dnPattern) {
        & $report 'DisabledOU' ("'{0}' is not a valid OU distinguished name (OU=...,DC=...,DC=...)." -f $disabledOu)
    }

    if ($Config.Contains('PasswordLength')) {
        $length = $Config['PasswordLength']
        if ($length -isnot [int] -or $length -lt 12 -or $length -gt 128) {
            & $report 'PasswordLength' 'Must be a whole number between 12 and 128.'
        }
    }

    $sites = $Config['Sites']
    if ($sites -isnot [System.Collections.IDictionary] -or $sites.Count -eq 0) {
        & $report 'Sites' 'Required. A hashtable of site name = OU distinguished name, with at least one site.'
    } else {
        foreach ($site in @($sites.Keys)) {
            $ou = $sites[$site]
            $setting = 'Sites.{0}' -f $site
            if ([string]::IsNullOrWhiteSpace([string]$ou)) {
                & $report $setting ("Site '{0}' has no OU." -f $site)
            } elseif ($ou -isnot [string] -or $ou -notmatch $dnPattern) {
                & $report $setting ("'{0}' is not a valid OU distinguished name (OU=...,DC=...,DC=...)." -f $ou)
            } elseif ($disabledOu -is [string] -and $ou -eq $disabledOu) {
                & $report 'DisabledOU' ("Must not be the same OU as site '{0}'." -f $site)
            }
        }
    }

    $departments = $Config['Departments']
    if ($departments -isnot [System.Collections.IDictionary] -or $departments.Count -eq 0) {
        & $report 'Departments' 'Required. A hashtable of department name = list of groups, with at least one department.'
    } else {
        foreach ($department in @($departments.Keys)) {
            & $testGroupList ('Departments.{0}' -f $department) $departments[$department] $false
        }
    }

    if ($Config.Contains('CommonGroups')) {
        & $testGroupList 'CommonGroups' $Config['CommonGroups'] $true
    }

    $problems
}
