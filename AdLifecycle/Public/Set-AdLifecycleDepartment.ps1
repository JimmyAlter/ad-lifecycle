function Set-AdLifecycleDepartment {
    <#
    .SYNOPSIS
        Moves an Active Directory user to another department (mover) using the group templates.

    .DESCRIPTION
        Compares the group list of the current department with the list of the new one:

        - Added:     groups in the new department only   -> added (unless already a member)
        - Removed:   groups in the old department only   -> removed (if the user is a member)
        - Unchanged: groups in both                      -> left alone

        CommonGroups and any group that is not in either template are never touched: this is a
        template diff, not a full reconciliation. The Department attribute is updated as well.

        The current department is read from the user's Department attribute; use -FromDepartment
        when that attribute is empty or wrong. ConfirmImpact is High, so PowerShell asks before
        changing anything; -WhatIf shows the plan and writes nothing. The plan is also returned
        as an object (Added, Removed, Unchanged).

        Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER Identity
        The user to move: sAMAccountName, DN, GUID or SID. Accepts pipeline input, including
        objects with a SamAccountName property.

    .PARAMETER Department
        The new department; must be a key of Departments in the configuration file.

    .PARAMETER FromDepartment
        Overrides the current department read from AD (for users whose attribute is missing or
        wrong). Must be a configured department.

    .PARAMETER ConfigPath
        Path to the .psd1 configuration file. See examples/lifecycle.config.psd1.

    .EXAMPLE
        Set-AdLifecycleDepartment -Identity jpena -Department Sales -ConfigPath .\lifecycle.config.psd1 -WhatIf

        Shows the groups that would be added and removed.

    .EXAMPLE
        Set-AdLifecycleDepartment -Identity jpena -Department Sales -ConfigPath .\lifecycle.config.psd1 -WhatIf |
            Format-List Added, Removed, Unchanged

        Reviews the diff as data.

    .EXAMPLE
        Set-AdLifecycleDepartment -Identity jpena -Department Sales -FromDepartment Finance -ConfigPath .\lifecycle.config.psd1

        Applies the move after confirmation, treating the user as coming from Finance.

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

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Department,

        [ValidateNotNullOrEmpty()]
        [string]$FromDepartment,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath
    )

    begin {
        Assert-AdModule
        $config = Get-AdLifecycleConfig -Path $ConfigPath

        $targetKey = Resolve-AdLifecycleConfigKey -Table $config.Departments -Name $Department
        if (-not $targetKey) {
            $known = ($config.Departments.Keys | Sort-Object) -join ', '
            throw ("Unknown department '{0}'. Configured departments: {1}." -f $Department, $known)
        }
    }

    process {
        try {
            $user = Get-ADUser -Identity $Identity -Properties Department -ErrorAction Stop
            if (-not $user -or -not $user.DistinguishedName) {
                throw 'No such user.'
            }
        } catch {
            Write-Error -Message ("User '{0}' was not found: {1}" -f $Identity, $_.Exception.Message) -Category ObjectNotFound -TargetObject $Identity
            return
        }
        $userDn = [string]$user.DistinguishedName

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

        $result = [pscustomobject]@{
            PSTypeName        = 'AdLifecycle.MoverResult'
            SamAccountName    = $user.SamAccountName
            DistinguishedName = $userDn
            FromDepartment    = $sourceKey
            ToDepartment      = $targetKey
            Added             = @($toGroups | Where-Object { $fromGroups -notcontains $_ })
            Removed           = @($fromGroups | Where-Object { $toGroups -notcontains $_ })
            Unchanged         = @($fromGroups | Where-Object { $toGroups -contains $_ })
            FailedGroups      = @()
            Applied           = $false
        }

        if ($sourceKey -eq $targetKey) {
            Write-Verbose ("'{0}' is already in department '{1}'; nothing to change." -f $user.SamAccountName, $targetKey)
            $result
            return
        }

        try {
            $currentGroups = @(Get-ADPrincipalGroupMembership -Identity $userDn -ErrorAction Stop | ForEach-Object { $_.SamAccountName })
        } catch {
            Write-Error -Message ("Could not read the group memberships of '{0}'; nothing was changed: {1}" -f $userDn, $_.Exception.Message) -Category ReadError -TargetObject $Identity
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
        $action = "Change department '{0}' -> '{1}'; add to: {2}; remove from: {3}" -f $sourceKey, $targetKey, $addText, $removeText
        $target = '{0} ({1})' -f $user.SamAccountName, $userDn
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            $result
            return
        }

        # Add first, then remove: the user is never left without the access of either department.
        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($group in $toAdd) {
            try {
                Add-ADGroupMember -Identity $group -Members $userDn -Confirm:$false -ErrorAction Stop
            } catch {
                $failed.Add($group)
                Write-Error -Message ("Adding '{0}' to group '{1}' failed: {2}" -f $user.SamAccountName, $group, $_.Exception.Message) -Category WriteError -TargetObject $group
            }
        }
        foreach ($group in $toRemove) {
            try {
                Remove-ADGroupMember -Identity $group -Members $userDn -Confirm:$false -ErrorAction Stop
            } catch {
                $failed.Add($group)
                Write-Error -Message ("Removing '{0}' from group '{1}' failed: {2}" -f $user.SamAccountName, $group, $_.Exception.Message) -Category WriteError -TargetObject $group
            }
        }

        try {
            Set-ADUser -Identity $userDn -Department $targetKey -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Error -Message ("Setting the Department attribute of '{0}' failed: {1}" -f $user.SamAccountName, $_.Exception.Message) -Category WriteError -TargetObject $Identity
        }

        $result.FailedGroups = $failed.ToArray()
        $result.Applied = $true
        $result
    }
}
