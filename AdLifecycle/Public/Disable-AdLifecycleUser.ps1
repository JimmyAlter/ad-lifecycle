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
        5. Moves the account to DisabledOU from the configuration (skipped if already there).

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

    .PARAMETER ExportPath
        Optional CSV file to append the recorded memberships to (UTF-8). Created if missing.

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
        AdLifecycle.LeaverResult. Applied is $false when -WhatIf was used or the prompt declined.
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
        [string]$ExportPath
    )

    begin {
        Assert-AdModule
        $config = Get-AdLifecycleConfig -Path $ConfigPath
        $disabledOu = [string]$config.DisabledOU

        $now = Get-Date
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $today = $now.ToString('yyyy-MM-dd', $invariant)
        $recordedAt = $now.ToString('yyyy-MM-dd HH:mm:ss', $invariant)

        $operator = [Environment]::UserName
        $userDomain = [Environment]::UserDomainName
        if ($userDomain -and $userDomain -ne [Environment]::MachineName) {
            $operator = '{0}\{1}' -f $userDomain, $operator
        }
    }

    process {
        try {
            $user = Get-ADUser -Identity $Identity -Properties Description, PrimaryGroupID -ErrorAction Stop
            if (-not $user -or -not $user.DistinguishedName) {
                throw 'No such user.'
            }
        } catch {
            Write-Error -Message ("User '{0}' was not found: {1}" -f $Identity, $_.Exception.Message) -Category ObjectNotFound -TargetObject $Identity
            return
        }
        $userDn = [string]$user.DistinguishedName

        try {
            $memberships = @(Get-ADPrincipalGroupMembership -Identity $userDn -ErrorAction Stop)
        } catch {
            Write-Error -Message ("Could not read the group memberships of '{0}'; nothing was changed: {1}" -f $userDn, $_.Exception.Message) -Category ReadError -TargetObject $Identity
            return
        }

        # The primary group cannot be removed (AD refuses) and Domain Users is kept on purpose.
        # Both are matched by RID so this also works when "Domain Users" is localized.
        $primaryRid = '513'
        if ($user.PrimaryGroupID) {
            $primaryRid = [string]$user.PrimaryGroupID
        }
        $isKept = {
            param([object]$Group)
            $sid = [string]$Group.SID
            $rid = $sid.Substring($sid.LastIndexOf('-') + 1)
            $rid -eq $primaryRid -or $rid -eq '513'
        }
        $kept = @($memberships | Where-Object { & $isKept $_ })
        $toRemove = @($memberships | Where-Object { -not (& $isKept $_) })

        $description = 'Disabled {0} by {1} - ticket {2}' -f $today, $operator, $Ticket
        $parentDn = $userDn -replace '^(?:[^,\\]|\\.)+,', ''
        $needsMove = $parentDn -ne $disabledOu

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
                    Kept                   = [bool](& $isKept $group)
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

        try {
            Disable-ADAccount -Identity $userDn -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Error -Message ("Failed to disable '{0}'; no other changes were made: {1}" -f $userDn, $_.Exception.Message) -Category WriteError -TargetObject $Identity
            return
        }
        $result.Applied = $true

        try {
            Set-ADUser -Identity $userDn -Description $description -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Error -Message ("'{0}' is disabled, but setting the description failed: {1}" -f $userDn, $_.Exception.Message) -Category WriteError -TargetObject $Identity
        }

        $removed = [System.Collections.Generic.List[string]]::new()
        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($group in $toRemove) {
            try {
                Remove-ADGroupMember -Identity $group.DistinguishedName -Members $userDn -Confirm:$false -ErrorAction Stop
                $removed.Add($group.Name)
            } catch {
                $failed.Add($group.Name)
                Write-Error -Message ("'{0}' is disabled, but removing it from group '{1}' failed: {2}" -f $userDn, $group.Name, $_.Exception.Message) -Category WriteError -TargetObject $group.Name
            }
        }
        $result.RemovedGroups = $removed.ToArray()
        $result.FailedGroups = $failed.ToArray()

        if ($needsMove) {
            try {
                Move-ADObject -Identity $userDn -TargetPath $disabledOu -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Error -Message ("'{0}' is disabled, but moving it to '{1}' failed: {2}" -f $userDn, $disabledOu, $_.Exception.Message) -Category WriteError -TargetObject $Identity
            }
        }

        $result
    }
}
