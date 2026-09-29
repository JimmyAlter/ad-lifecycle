function Set-AdLifecycleUser {
    <#
    .SYNOPSIS
        Applies a mover change to an Active Directory user: department groups, site OU, title, manager.

    .DESCRIPTION
        Plans every requested change for a user, shows it in one confirmation, and applies it:

        - -Department: compares the group list of the current department with the list of the
          new one and applies the difference, then updates the Department attribute.
            Added:     groups in the new department only   -> added (unless already a member)
            Removed:   groups in the old department only   -> removed (if the user is a member)
            Unchanged: groups in both                      -> left alone
          CommonGroups and any group that is not in either template are never touched: this is a
          template diff, not a full reconciliation. The current department is read from the
          user's Department attribute; use -FromDepartment when that attribute is empty or wrong.
        - -Site: moves the account to the OU mapped to that site (Move-ADObject) and sets Office
          to the site name, as the joiner does.
        - -Title: sets the job title.
        - -Manager: resolved to a distinguished name like the joiner does; must exist in AD.

        At least one of -Department, -Site, -Title or -Manager is required. Values that already
        match are not rewritten; when nothing differs, nothing is written and Applied is $false.

        Order when applying: group adds, group removals (the user is never left without the
        access of either department), one Set-ADUser call for the attributes, and the OU move
        last. Failures are reported as errors and listed in the result without stopping the
        remaining steps.

        Group memberships are compared by DN against the user's memberOf; every template group
        involved is resolved first (Get-ADGroup), and if one cannot be resolved nothing is
        changed for that user.

        Safety guard, as in Disable-AdLifecycleUser: the built-in Administrator (RID 500) and
        krbtgt (RID 502) are refused, and protected accounts (adminCount = 1, or members, also
        nested, of Domain Admins, Schema Admins, Enterprise Admins or BUILTIN\Administrators)
        are refused unless -Force is used. Nothing is changed for a refused user.

        ConfirmImpact is High, so PowerShell asks before changing anything; -WhatIf shows the plan
        and writes nothing. Set-AdLifecycleDepartment is an alias of this command, kept for
        backward compatibility with 0.1.0. Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER Identity
        The user to change: sAMAccountName, DN, GUID or SID. Accepts pipeline input, including
        objects with a SamAccountName property.

    .PARAMETER Department
        The new department; must be a key of Departments in the configuration file.

    .PARAMETER FromDepartment
        Overrides the current department read from AD (for users whose attribute is missing or
        wrong). Must be a configured department. Only used with -Department.

    .PARAMETER Site
        The new site; must be a key of Sites in the configuration file. The account is moved to
        that site's OU.

    .PARAMETER Title
        The new job title.

    .PARAMETER Manager
        The new manager (sAMAccountName, DN, GUID or SID). Must exist in AD.

    .PARAMETER Force
        Allows changing protected accounts (adminCount = 1, or members of Domain Admins, Schema
        Admins, Enterprise Admins or BUILTIN\Administrators). The built-in Administrator
        (RID 500) and krbtgt (RID 502) are always refused. It does not skip the confirmation.

    .PARAMETER ConfigPath
        Path to the .psd1 configuration file. See examples/lifecycle.config.psd1.

    .PARAMETER Server
        Domain controller to use for every read and write. When omitted, one writable domain
        controller is located once (Get-ADDomainController -Discover -Writable) and pinned for the
        whole run, so every step for a user goes to the same DC.

    .PARAMETER Credential
        Account to connect to Active Directory as. Defaults to the current user.

    .PARAMETER Ticket
        Optional ticket or request id (letters, digits and # . / - _; up to 64 characters),
        recorded in the audit log.

    .PARAMETER LogPath
        Optional audit log file: one JSON line per user changed (UTC timestamp, operator, ticket,
        planned changes, result). Overrides LogPath from the configuration. The folder must
        exist. Nothing is logged under -WhatIf.

    .EXAMPLE
        Set-AdLifecycleUser -Identity jpena -Department Sales -ConfigPath .\lifecycle.config.psd1 -WhatIf

        Shows the groups that would be added and removed.

    .EXAMPLE
        Set-AdLifecycleUser -Identity jpena -Department Sales -Site Cordoba -Title 'Account Executive' -Manager mlopez -ConfigPath .\lifecycle.config.psd1

        A full internal transfer, applied after one confirmation: department groups, OU, title
        and manager.

    .EXAMPLE
        Set-AdLifecycleUser -Identity jpena -Department Sales -FromDepartment Finance -ConfigPath .\lifecycle.config.psd1 -WhatIf |
            Format-List Added, Removed, Unchanged

        Reviews the diff as data, treating the user as coming from Finance.

    .OUTPUTS
        AdLifecycle.MoverResult. Applied is $false when -WhatIf was used, the prompt was declined
        or there was nothing to change.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('AdLifecycle.MoverResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName')]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [ValidateNotNullOrEmpty()]
        [string]$Department,

        [ValidateNotNullOrEmpty()]
        [string]$FromDepartment,

        [ValidateNotNullOrEmpty()]
        [string]$Site,

        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [ValidateNotNullOrEmpty()]
        [string]$Manager,

        [switch]$Force,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [AllowNull()]
        [ValidatePattern('^([\w#./-]{1,64})?$')]
        [string]$Ticket,

        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        if (-not ($Department -or $Site -or $Title -or $Manager)) {
            throw 'Nothing to change: pass at least one of -Department, -Site, -Title or -Manager.'
        }

        Assert-AdModule
        $config = Get-AdLifecycleConfig -Path $ConfigPath

        $targetKey = $null
        if ($Department) {
            $targetKey = Resolve-AdLifecycleConfigKey -Table $config.Departments -Name $Department
            if (-not $targetKey) {
                $known = ($config.Departments.Keys | Sort-Object) -join ', '
                throw ("Unknown department '{0}'. Configured departments: {1}." -f $Department, $known)
            }
        }

        $siteKey = $null
        $targetOu = $null
        if ($Site) {
            $siteKey = Resolve-AdLifecycleConfigKey -Table $config.Sites -Name $Site
            if (-not $siteKey) {
                $known = ($config.Sites.Keys | Sort-Object) -join ', '
                throw ("Unknown site '{0}'. Configured sites: {1}." -f $Site, $known)
            }
            $targetOu = [string]$config.Sites[$siteKey]
        }

        $connection = Get-AdLifecycleConnection -Server $Server -Credential $Credential -DiscoverWritable
        $auditLog = Resolve-AdLifecycleLogPath -LogPath $LogPath -Config $config

        $managerDn = $null
        if ($Manager) {
            try {
                $managerUser = Get-ADUser -Identity $Manager.Trim() -ErrorAction Stop @connection
                if (-not $managerUser -or -not $managerUser.DistinguishedName) {
                    throw 'No such user.'
                }
                $managerDn = [string]$managerUser.DistinguishedName
            } catch {
                throw ("Manager '{0}' was not found in Active Directory: {1}" -f $Manager, $_.Exception.Message)
            }
        }
    }

    process {
        try {
            $user = Get-ADUser -Identity $Identity -Properties Department, MemberOf, Title, Manager, Office, PrimaryGroupID, adminCount, tokenGroups -ErrorAction Stop @connection
            if (-not $user -or -not $user.DistinguishedName) {
                throw 'No such user.'
            }
        } catch {
            Write-Error -Message ("User '{0}' was not found: {1}" -f $Identity, $_.Exception.Message) -Category ObjectNotFound -TargetObject $Identity
            return
        }
        $userDn = [string]$user.DistinguishedName

        # Same guard as the leaver (without the own-account check): never RID 500 or 502, and
        # protected accounts only with -Force.
        $refusal = Get-AdLifecycleProtectionIssue -User $user -Force:$Force
        if ($refusal) {
            Write-Error -Message ("Refusing to change '{0}': {1}. Nothing was changed." -f $user.SamAccountName, $refusal) -Category PermissionDenied -TargetObject $Identity
            return
        }
        $rdn = $userDn -replace '^((?:[^,\\]|\\.)+),.*$', '$1'
        $parentDn = $userDn.Substring($rdn.Length + 1)

        $result = [pscustomobject]@{
            PSTypeName        = 'AdLifecycle.MoverResult'
            SamAccountName    = $user.SamAccountName
            DistinguishedName = $userDn
            FromDepartment    = $null
            ToDepartment      = $null
            Added             = @()
            Removed           = @()
            Unchanged         = @()
            PreviousTitle     = $user.Title
            Title             = $user.Title
            PreviousManager   = $user.Manager
            Manager           = $user.Manager
            PreviousOU        = $parentDn
            TargetOU          = $parentDn
            FailedGroups      = @()
            Applied           = $false
        }

        $steps = [System.Collections.Generic.List[string]]::new()
        $attributes = @{}
        $toAdd = @()
        $toRemove = @()

        if ($targetKey) {
            $sourceName = [string]$user.Department
            if ($FromDepartment) {
                $sourceName = $FromDepartment
            }
            if ([string]::IsNullOrWhiteSpace($sourceName)) {
                Write-Error -Message ("User '{0}' has no Department attribute; pass -FromDepartment." -f $user.SamAccountName) -Category InvalidData -TargetObject $Identity
                return
            }
            $sourceKey = Resolve-AdLifecycleConfigKey -Table $config.Departments -Name $sourceName
            if (-not $sourceKey) {
                Write-Error -Message ("Current department '{0}' of '{1}' is not in the configuration; pass -FromDepartment with a configured department." -f $sourceName, $user.SamAccountName) -Category InvalidData -TargetObject $Identity
                return
            }

            $fromGroups = @($config.Departments[$sourceKey])
            $toGroups = @($config.Departments[$targetKey])
            $result.FromDepartment = $sourceKey
            $result.ToDepartment = $targetKey

            if ($sourceKey -eq $targetKey) {
                Write-Verbose ("'{0}' is already in department '{1}'; no group changes." -f $user.SamAccountName, $targetKey)
            } else {
                $result.Added = @($toGroups | Where-Object { $fromGroups -notcontains $_ })
                $result.Removed = @($fromGroups | Where-Object { $toGroups -notcontains $_ })
                $result.Unchanged = @($fromGroups | Where-Object { $toGroups -contains $_ })

                # Resolve every template group involved to its DN and compare with the user's
                # memberOf. (Get-ADPrincipalGroupMembership is not used: it fails for users in
                # groups that contain foreign security principals.) A group that cannot be
                # resolved stops this user.
                $memberOf = @($user.MemberOf | ForEach-Object { [string]$_ })
                $currentGroups = [System.Collections.Generic.List[string]]::new()
                try {
                    foreach ($name in @(@($result.Added) + @($result.Removed))) {
                        $group = Get-ADGroup -Identity $name -ErrorAction Stop @connection
                        if (-not $group -or -not $group.DistinguishedName) {
                            throw ("Group '{0}' was not found." -f $name)
                        }
                        if ($memberOf -contains [string]$group.DistinguishedName) {
                            $currentGroups.Add($name)
                        }
                    }
                } catch {
                    Write-Error -Message ("Could not resolve the template groups for '{0}'; nothing was changed: {1}" -f $userDn, $_.Exception.Message) -Category ReadError -TargetObject $Identity
                    return
                }

                $toAdd = @($result.Added | Where-Object { $currentGroups -notcontains $_ })
                $toRemove = @($result.Removed | Where-Object { $currentGroups -contains $_ })
                foreach ($group in @($result.Added | Where-Object { $currentGroups -contains $_ })) {
                    Write-Verbose ("'{0}' is already a member of '{1}'." -f $user.SamAccountName, $group)
                }
                foreach ($group in @($result.Removed | Where-Object { $currentGroups -notcontains $_ })) {
                    Write-Verbose ("'{0}' is not a member of '{1}'; nothing to remove." -f $user.SamAccountName, $group)
                }

                $addText = '(none)'
                if ($toAdd.Count -gt 0) {
                    $addText = $toAdd -join ', '
                }
                $removeText = '(none)'
                if ($toRemove.Count -gt 0) {
                    $removeText = $toRemove -join ', '
                }
                $steps.Add(("Change department '{0}' -> '{1}'; add to: {2}; remove from: {3}" -f $sourceKey, $targetKey, $addText, $removeText))
            }
            if ([string]$user.Department -cne $targetKey -and $sourceKey -ne $targetKey) {
                $attributes['Department'] = $targetKey
            }
        }

        if ($Title -and [string]$user.Title -cne $Title) {
            $attributes['Title'] = $Title
            $result.Title = $Title
            $steps.Add(("set Title '{0}'" -f $Title))
        }

        if ($managerDn -and [string]$user.Manager -ne $managerDn) {
            $attributes['Manager'] = $managerDn
            $result.Manager = $managerDn
            $steps.Add(("set Manager '{0}'" -f $managerDn))
        }

        $needsMove = $false
        if ($siteKey) {
            if ([string]$user.Office -cne $siteKey) {
                $attributes['Office'] = $siteKey
                $steps.Add(("set Office '{0}'" -f $siteKey))
            }
            if ($parentDn -ne $targetOu) {
                $needsMove = $true
                $result.TargetOU = $targetOu
                $steps.Add(("move to '{0}'" -f $targetOu))
            }
        }

        if ($steps.Count -eq 0) {
            Write-Verbose ("'{0}' already matches the requested values; nothing to change." -f $user.SamAccountName)
            $result
            return
        }

        $target = '{0} ({1})' -f $user.SamAccountName, $userDn
        if (-not $PSCmdlet.ShouldProcess($target, ($steps -join '; '))) {
            $result
            return
        }

        # Everything below changes AD; the finally block writes the audit log line even when a
        # caller's -ErrorAction Stop turns one of the errors into a terminating one.
        $failed = [System.Collections.Generic.List[string]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()
        try {
            # Add first, then remove: the user is never left without the access of either department.
            foreach ($group in $toAdd) {
                try {
                    Add-ADGroupMember -Identity $group -Members $userDn -Confirm:$false -ErrorAction Stop @connection
                } catch {
                    $failed.Add($group)
                    $message = "Adding '{0}' to group '{1}' failed: {2}" -f $user.SamAccountName, $group, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $group
                }
            }
            foreach ($group in $toRemove) {
                try {
                    Remove-ADGroupMember -Identity $group -Members $userDn -Confirm:$false -ErrorAction Stop @connection
                } catch {
                    $failed.Add($group)
                    $message = "Removing '{0}' from group '{1}' failed: {2}" -f $user.SamAccountName, $group, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $group
                }
            }
            $result.FailedGroups = $failed.ToArray()
            $result.Applied = $true

            if ($attributes.Count -gt 0) {
                try {
                    Set-ADUser -Identity $userDn @attributes -Confirm:$false -ErrorAction Stop @connection
                } catch {
                    $message = "Setting {0} of '{1}' failed: {2}" -f (($attributes.Keys | Sort-Object) -join ', '), $user.SamAccountName, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $Identity
                }
            }

            # The move changes the DN, so it goes last.
            if ($needsMove) {
                try {
                    Move-ADObject -Identity $userDn -TargetPath $targetOu -Confirm:$false -ErrorAction Stop @connection
                    $result.DistinguishedName = '{0},{1}' -f $rdn, $targetOu
                } catch {
                    $message = "Moving '{0}' to '{1}' failed: {2}" -f $user.SamAccountName, $targetOu, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $Identity
                }
            }

            $result
        } finally {
            if ($auditLog) {
                $moveTo = $null
                if ($needsMove) {
                    $moveTo = $targetOu
                }
                $changes = [ordered]@{
                    FromDepartment = $result.FromDepartment
                    ToDepartment   = $result.ToDepartment
                    AddGroups      = @($toAdd)
                    RemoveGroups   = @($toRemove)
                    Attributes     = $attributes
                    MoveTo         = $moveTo
                }
                Write-AdLifecycleAuditLog -Path $auditLog -Command 'Set-AdLifecycleUser' -Target ([string]$user.SamAccountName) `
                    -DistinguishedName $userDn -Ticket $Ticket -Changes $changes -Applied $result.Applied `
                    -FailedGroups $failed.ToArray() -Errors $errors.ToArray() -Connection $connection
            }
        }
    }
}
