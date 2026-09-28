function Disable-AdLifecycleUser {
    <#
    .SYNOPSIS
        Offboards an Active Directory user (leaver): disable, record and strip groups, tag, move.

    .DESCRIPTION
        For each user, after confirmation:

        1. Records every current group membership in the output object and, with -ExportPath,
           appends it to a CSV before anything is changed (if the CSV cannot be written, the user
           is left untouched).
        2. Disables the account. If this fails, nothing else is changed for that user.
        3. Sets the description to "Disabled yyyy-MM-dd by <operator> - ticket <id>".
        4. Removes every group membership except the primary group and Domain Users. Both are
           matched by RID (primaryGroupID and 513), not by name, so localized domains work.
           Memberships are read from the user's memberOf and primaryGroupID, not with
           Get-ADPrincipalGroupMembership, which fails for users in groups that contain foreign
           security principals.
        5. Moves the account to DisabledOU from the configuration (skipped if already there).

        Safety guard: the command refuses, with an error and without changing anything, the
        built-in Administrator (RID 500), krbtgt (RID 502) and the account running it (the
        current Windows user, or the -Credential account). Accounts with adminCount = 1 (current
        or former members of protected groups) are refused unless -Force is used.

        Idempotent: an account that is already disabled and already in DisabledOU is skipped with
        a warning (Skipped = $true), so re-running a bulk CSV does not overwrite the original
        description, date and ticket.

        -Ticket is mandatory: every leaver is traceable to a request. ConfirmImpact is High, so
        PowerShell asks before changing anything; -WhatIf shows the plan and writes nothing
        (not even the CSV). Failures in steps 3-5 are reported as errors and listed in the result
        without stopping the remaining steps.

        Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER Identity
        The user to offboard: sAMAccountName, DN, GUID or SID. Accepts pipeline input, including
        objects with a SamAccountName property (Get-ADUser output, Import-Csv rows).

    .PARAMETER Ticket
        Ticket or request id (letters, digits and # . / - _; up to 64 characters). Written into
        the description and the CSV.

    .PARAMETER ConfigPath
        Path to the .psd1 configuration file. See examples/lifecycle.config.psd1.

    .PARAMETER Server
        Domain controller to use for every read and write. When omitted, one writable domain
        controller is located once (Get-ADDomainController -Discover -Writable) and pinned for the
        whole run, so every step for a user goes to the same DC.

    .PARAMETER Credential
        Account to connect to Active Directory as. Defaults to the current user.

    .PARAMETER ExportPath
        Optional CSV file to append the recorded memberships to (UTF-8). Created if missing.

    .PARAMETER Force
        Allows offboarding accounts with adminCount = 1 (current or former members of protected
        groups such as Domain Admins). It does not lift the refusal for the built-in Administrator
        (RID 500), krbtgt (RID 502) or your own account, and it does not skip the confirmation.

    .PARAMETER LogPath
        Optional audit log file: one JSON line per offboarded user (UTC timestamp, operator,
        ticket, planned changes, result). Overrides LogPath from the configuration. The folder
        must exist. Nothing is logged under -WhatIf.

    .EXAMPLE
        Disable-AdLifecycleUser -Identity jpena -Ticket INC-4821 -ConfigPath .\lifecycle.config.psd1 -WhatIf

        Shows which groups would be removed, the new description and the target OU.

    .EXAMPLE
        Disable-AdLifecycleUser -Identity jpena -Ticket INC-4821 -ConfigPath .\lifecycle.config.psd1 -ExportPath .\leavers.csv

        Offboards jpena after confirmation and keeps a CSV record of the memberships removed.

    .EXAMPLE
        Import-Csv .\leavers.csv | Disable-AdLifecycleUser -ConfigPath .\lifecycle.config.psd1 -ExportPath .\removed.csv -Confirm:$false

        Bulk leavers from a CSV with SamAccountName and Ticket columns.

    .OUTPUTS
        AdLifecycle.LeaverResult. Applied is $false when -WhatIf was used, the prompt was declined
        or the account was skipped because it was already offboarded (Skipped = $true).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('AdLifecycle.LeaverResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName')]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[\w#./-]{1,64}$')]
        [string]$Ticket,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [ValidateNotNullOrEmpty()]
        [string]$ExportPath,

        [switch]$Force,

        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        Assert-AdModule
        $config = Get-AdLifecycleConfig -Path $ConfigPath
        $connection = Get-AdLifecycleConnection -Server $Server -Credential $Credential -DiscoverWritable
        $disabledOu = [string]$config.DisabledOU

        $now = Get-Date
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $today = $now.ToString('yyyy-MM-dd', $invariant)
        $recordedAt = $now.ToString('yyyy-MM-dd HH:mm:ss', $invariant)

        $operator = Get-AdLifecycleOperator
        $auditLog = Resolve-AdLifecycleLogPath -LogPath $LogPath -Config $config

        $callerSid = Get-AdLifecycleCallerSid
        # With -Credential the AD calls run as that account: protect it as well.
        $credentialName = $null
        if ($connection.ContainsKey('Credential')) {
            # DOMAIN\name or name@domain -> name
            $credentialName = [string]$connection['Credential'].UserName -replace '^.*\\', '' -replace '@.*$', ''
        }
    }

    process {
        try {
            $user = Get-ADUser -Identity $Identity -Properties Description, PrimaryGroupID, MemberOf, adminCount -ErrorAction Stop @connection
            if (-not $user -or -not $user.DistinguishedName) {
                throw 'No such user.'
            }
        } catch {
            Write-Error -Message ("User '{0}' was not found: {1}" -f $Identity, $_.Exception.Message) -Category ObjectNotFound -TargetObject $Identity
            return
        }
        $userDn = [string]$user.DistinguishedName

        # Safety guard, before anything else is read or planned. The built-in Administrator
        # (RID 500), krbtgt (RID 502) and the caller's own account are never offboarded here;
        # protected accounts (adminCount = 1) only with -Force.
        $userSid = [string]$user.SID
        $rid = $userSid.Substring($userSid.LastIndexOf('-') + 1)
        $refusal = $null
        if ($rid -eq '500') {
            $refusal = 'it is the built-in Administrator account (RID 500)'
        } elseif ($rid -eq '502') {
            $refusal = 'it is the krbtgt account (RID 502)'
        } elseif (($callerSid -and $userSid -eq $callerSid) -or
            ($credentialName -and [string]$user.SamAccountName -eq $credentialName)) {
            $refusal = 'it is the account running this command'
        } elseif ([string]$user.adminCount -eq '1' -and -not $Force) {
            $refusal = 'adminCount is 1 (it is, or was, in a protected group such as Domain Admins); review it and use -Force to offboard it anyway'
        }
        if ($refusal) {
            Write-Error -Message ("Refusing to offboard '{0}': {1}. Nothing was changed." -f $user.SamAccountName, $refusal) -Category PermissionDenied -TargetObject $Identity
            return
        }

        $parentDn = $userDn -replace '^(?:[^,\\]|\\.)+,', ''
        $needsMove = $parentDn -ne $disabledOu

        # Already offboarded (disabled and in DisabledOU): leave it alone, so a re-run of a bulk
        # CSV does not overwrite the original description, date and ticket.
        if ($user.Enabled -eq $false -and -not $needsMove) {
            Write-Warning ("'{0}' is already disabled and in '{1}'; skipped (description and groups left as they are)." -f $user.SamAccountName, $disabledOu)
            [pscustomobject]@{
                PSTypeName          = 'AdLifecycle.LeaverResult'
                SamAccountName      = $user.SamAccountName
                DistinguishedName   = $userDn
                Ticket              = $Ticket
                Description         = $user.Description
                PreviousDescription = $user.Description
                PreviousGroups      = @()
                KeptGroups          = @()
                RemovedGroups       = @()
                FailedGroups        = @()
                TargetOU            = $disabledOu
                ExportPath          = $null
                Skipped             = $true
                Applied             = $false
            }
            return
        }

        try {
            $memberships = @(Get-AdLifecycleUserGroup -User $user -Connection $connection)
        } catch {
            Write-Error -Message ("Could not read the group memberships of '{0}'; nothing was changed: {1}" -f $userDn, $_.Exception.Message) -Category ReadError -TargetObject $Identity
            return
        }

        # The primary group cannot be removed (AD refuses) and Domain Users is kept on purpose.
        # Both are matched by RID so this also works when "Domain Users" is localized.
        $kept = @($memberships | Where-Object { $_.IsPrimary -or $_.IsDomainUsers })
        $toRemove = @($memberships | Where-Object { -not ($_.IsPrimary -or $_.IsDomainUsers) })

        $description = 'Disabled {0} by {1} - ticket {2}' -f $today, $operator, $Ticket

        $result = [pscustomobject]@{
            PSTypeName          = 'AdLifecycle.LeaverResult'
            SamAccountName      = $user.SamAccountName
            DistinguishedName   = $userDn
            Ticket              = $Ticket
            Description         = $description
            PreviousDescription = $user.Description
            PreviousGroups      = @($memberships | ForEach-Object { $_.Name })
            KeptGroups          = @($kept | ForEach-Object { $_.Name })
            RemovedGroups       = @($toRemove | ForEach-Object { $_.Name })
            FailedGroups        = @()
            TargetOU            = $disabledOu
            ExportPath          = $null
            Skipped             = $false
            Applied             = $false
        }

        $steps = [System.Collections.Generic.List[string]]::new()
        $steps.Add('Disable the account')
        $steps.Add("set description '$description'")
        if ($toRemove.Count -gt 0) {
            $steps.Add(('remove from {0} group(s): {1}' -f $toRemove.Count, ($result.RemovedGroups -join ', ')))
        } else {
            $steps.Add('no group memberships to remove')
        }
        if ($kept.Count -gt 0) {
            $steps.Add(('keep {0}' -f ($result.KeptGroups -join ', ')))
        }
        if ($needsMove) {
            $steps.Add("move to '$disabledOu'")
        } else {
            $steps.Add("already in '$disabledOu'")
        }

        $target = '{0} ({1})' -f $user.SamAccountName, $userDn
        if (-not $PSCmdlet.ShouldProcess($target, ($steps -join '; '))) {
            $result
            return
        }

        if ($ExportPath) {
            $rows = foreach ($group in $memberships) {
                [pscustomobject]@{
                    SamAccountName         = $user.SamAccountName
                    UserDistinguishedName  = $userDn
                    GroupName              = $group.Name
                    GroupDistinguishedName = $group.DistinguishedName
                    Kept                   = [bool]($group.IsPrimary -or $group.IsDomainUsers)
                    Ticket                 = $Ticket
                    Operator               = $operator
                    RecordedAt             = $recordedAt
                }
            }
            try {
                $rows | Export-Csv -LiteralPath $ExportPath -NoTypeInformation -Encoding UTF8 -Append -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Error -Message ("Could not write the membership record to '{0}'; '{1}' was not changed: {2}" -f $ExportPath, $user.SamAccountName, $_.Exception.Message) -Category WriteError -TargetObject $ExportPath
                return
            }
            $result.ExportPath = $ExportPath
        }

        # Everything below changes AD; the finally block writes the audit log line even when a
        # caller's -ErrorAction Stop turns one of the errors into a terminating one.
        $errors = [System.Collections.Generic.List[string]]::new()
        $removed = [System.Collections.Generic.List[string]]::new()
        $failed = [System.Collections.Generic.List[string]]::new()
        try {
            try {
                Disable-ADAccount -Identity $userDn -Confirm:$false -ErrorAction Stop @connection
            } catch {
                $message = "Failed to disable '{0}'; no other changes were made: {1}" -f $userDn, $_.Exception.Message
                $errors.Add($message)
                Write-Error -Message $message -Category WriteError -TargetObject $Identity
                return
            }
            $result.Applied = $true

            try {
                Set-ADUser -Identity $userDn -Description $description -Confirm:$false -ErrorAction Stop @connection
            } catch {
                $message = "'{0}' is disabled, but setting the description failed: {1}" -f $userDn, $_.Exception.Message
                $errors.Add($message)
                Write-Error -Message $message -Category WriteError -TargetObject $Identity
            }

            foreach ($group in $toRemove) {
                try {
                    Remove-ADGroupMember -Identity $group.DistinguishedName -Members $userDn -Confirm:$false -ErrorAction Stop @connection
                    $removed.Add($group.Name)
                } catch {
                    $failed.Add($group.Name)
                    $message = "'{0}' is disabled, but removing it from group '{1}' failed: {2}" -f $userDn, $group.Name, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $group.Name
                }
            }
            $result.RemovedGroups = $removed.ToArray()
            $result.FailedGroups = $failed.ToArray()

            if ($needsMove) {
                try {
                    Move-ADObject -Identity $userDn -TargetPath $disabledOu -Confirm:$false -ErrorAction Stop @connection
                } catch {
                    $message = "'{0}' is disabled, but moving it to '{1}' failed: {2}" -f $userDn, $disabledOu, $_.Exception.Message
                    $errors.Add($message)
                    Write-Error -Message $message -Category WriteError -TargetObject $Identity
                }
            }

            $result
        } finally {
            if ($auditLog) {
                $moveTo = $null
                if ($needsMove) {
                    $moveTo = $disabledOu
                }
                $changes = [ordered]@{
                    Disable      = $true
                    Description  = $description
                    RemoveGroups = @($toRemove | ForEach-Object { $_.Name })
                    KeptGroups   = @($kept | ForEach-Object { $_.Name })
                    MoveTo       = $moveTo
                    ExportPath   = $result.ExportPath
                }
                Write-AdLifecycleAuditLog -Path $auditLog -Command 'Disable-AdLifecycleUser' -Target ([string]$user.SamAccountName) `
                    -DistinguishedName $userDn -Ticket $Ticket -Changes $changes -Applied $result.Applied `
                    -FailedGroups $failed.ToArray() -Errors $errors.ToArray() -Connection $connection
            }
        }
    }
}
