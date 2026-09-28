function New-AdLifecycleUser {
    <#
    .SYNOPSIS
        Creates a new Active Directory user (joiner) from the site and department templates.

    .DESCRIPTION
        Works out everything from the configuration file, shows it, and only writes after you
        confirm:

        - sAMAccountName: first initial + surname, lowercase, diacritics stripped, only a-z/0-9,
          at most 20 characters, with 2, 3, ... appended when the name (or its UPN) is taken
        - UserPrincipalName: <samAccountName>@<UpnSuffix>
        - OU: the OU mapped to -Site
        - groups: CommonGroups + the groups of -Department
        - a random initial password (System.Security.Cryptography) with guaranteed complexity,
          and "User must change password at next logon"

        ConfirmImpact is High, so PowerShell asks before creating anything. Use -WhatIf to see the
        plan, or -Confirm:$false in unattended runs. Lookups (name collisions, manager) run even
        with -WhatIf, so the plan shows the real sAMAccountName.

        The initial password is only returned as a SecureString (InitialPassword). This command
        never writes it to the console, a log or a file.

        If the account is created but adding it to a group fails, a warning is written, the
        group is listed in FailedGroups, and the result (with the password) is still returned,
        even under -ErrorAction Stop, so an account never ends up with a password nobody knows.

        Requires the ActiveDirectory module (RSAT) at run time.

    .PARAMETER GivenName
        First name, as it should appear in AD (diacritics are kept in the display name).

    .PARAMETER Surname
        Last name(s), as they should appear in AD.

    .PARAMETER Department
        Department name; must be a key of Departments in the configuration file.

    .PARAMETER Site
        Site name; must be a key of Sites in the configuration file. Decides the OU.

    .PARAMETER Title
        Job title.

    .PARAMETER Manager
        Optional manager (sAMAccountName, DN, GUID or SID). Must exist in AD.

    .PARAMETER ConfigPath
        Path to the .psd1 configuration file. See examples/lifecycle.config.psd1.

    .PARAMETER Server
        Domain controller to use for every read and write. When omitted, one writable domain
        controller is located once (Get-ADDomainController -Discover -Writable) and pinned for the
        whole run, so the group adds go to the same DC that created the account.

    .PARAMETER Credential
        Account to connect to Active Directory as. Defaults to the current user.

    .EXAMPLE
        New-AdLifecycleUser -GivenName 'Jose' -Surname 'Pena' -Department Finance -Site Madrid -Title 'Accountant' -ConfigPath .\lifecycle.config.psd1 -WhatIf

        Shows the account that would be created (sAMAccountName jpena, UPN, OU, groups) without
        changing anything.

    .EXAMPLE
        Import-Csv .\new-hires.csv -Encoding UTF8 | New-AdLifecycleUser -ConfigPath .\lifecycle.config.psd1 -Confirm:$false

        Bulk joiners from a CSV with GivenName, Surname, Department, Site, Title and Manager
        columns. Names handed out earlier in the same run are not reused.

    .EXAMPLE
        $new = New-AdLifecycleUser -GivenName 'Ana' -Surname 'Gomez' -Department Sales -Site 'Buenos Aires' -Title 'Account Executive' -Manager mlopez -ConfigPath .\lifecycle.config.psd1
        [System.Net.NetworkCredential]::new('', $new.InitialPassword).Password | Set-Clipboard

        Creates the user after confirmation and copies the initial password to the clipboard to
        hand over through your usual secure channel.

    .OUTPUTS
        AdLifecycle.NewUserResult. Applied is $false when -WhatIf was used or the prompt declined.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('AdLifecycle.NewUserResult')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$GivenName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Surname,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Department,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Site,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Manager,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

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

        $passwordLength = 16
        if ($config.Contains('PasswordLength')) {
            $passwordLength = [int]$config['PasswordLength']
        }

        # sAMAccountNames handed out earlier in this pipeline run. AD may not show them yet
        # (-WhatIf, or replication), and two new hires can share a name.
        $assigned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    process {
        $GivenName = $GivenName.Trim()
        $Surname = $Surname.Trim()

        $departmentKey = Resolve-AdLifecycleConfigKey -Table $config.Departments -Name $Department
        if (-not $departmentKey) {
            $known = ($config.Departments.Keys | Sort-Object) -join ', '
            $message = "Unknown department '{0}'. Configured departments: {1}." -f $Department, $known
            Write-Error -Message $message -Category InvalidArgument -TargetObject $Department
            return
        }

        $siteKey = Resolve-AdLifecycleConfigKey -Table $config.Sites -Name $Site
        if (-not $siteKey) {
            $known = ($config.Sites.Keys | Sort-Object) -join ', '
            $message = "Unknown site '{0}'. Configured sites: {1}." -f $Site, $known
            Write-Error -Message $message -Category InvalidArgument -TargetObject $Site
            return
        }
        $ou = [string]$config.Sites[$siteKey]

        # CommonGroups first, then the department's groups; de-duplicated, order kept.
        $groups = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($group in @(@($config['CommonGroups']) + @($config.Departments[$departmentKey]))) {
            if ($group -and $seen.Add($group)) {
                $groups.Add($group)
            }
        }

        $managerDn = $null
        if (-not [string]::IsNullOrWhiteSpace($Manager)) {
            try {
                $managerUser = Get-ADUser -Identity $Manager.Trim() -ErrorAction Stop @connection
                if (-not $managerUser) {
                    throw 'No such user.'
                }
                $managerDn = [string]$managerUser.DistinguishedName
            } catch {
                Write-Error -Message ("Manager '{0}' was not found in Active Directory: {1}" -f $Manager, $_.Exception.Message) -Category ObjectNotFound -TargetObject $Manager
                return
            }
        }

        try {
            $sam = Resolve-AdSamAccountName -GivenName $GivenName -Surname $Surname -UpnSuffix $config.UpnSuffix -Reserved @($assigned) -Connection $connection
        } catch {
            Write-Error -Message $_.Exception.Message -Category InvalidData -TargetObject ('{0} {1}' -f $GivenName, $Surname)
            return
        }
        [void]$assigned.Add($sam)

        $upn = '{0}@{1}' -f $sam, $config.UpnSuffix
        $displayName = '{0} {1}' -f $GivenName, $Surname

        $result = [pscustomobject]@{
            PSTypeName        = 'AdLifecycle.NewUserResult'
            SamAccountName    = $sam
            UserPrincipalName = $upn
            DisplayName       = $displayName
            OU                = $ou
            DistinguishedName = $null
            Department        = $departmentKey
            Site              = $siteKey
            Title             = $Title
            Manager           = $managerDn
            Groups            = $groups.ToArray()
            FailedGroups      = @()
            InitialPassword   = $null
            Applied           = $false
        }

        $action = "Create user '{0}' in '{1}' and add to {2} group(s): {3}" -f $displayName, $ou, $groups.Count, ($groups -join ', ')
        if (-not $PSCmdlet.ShouldProcess($upn, $action)) {
            $result
            return
        }

        $password = New-AdInitialPassword -Length $passwordLength
        $newUserParams = @{
            Name                  = $displayName
            DisplayName           = $displayName
            GivenName             = $GivenName
            Surname               = $Surname
            SamAccountName        = $sam
            UserPrincipalName     = $upn
            Path                  = $ou
            Department            = $departmentKey
            Title                 = $Title
            Office                = $siteKey
            AccountPassword       = $password
            ChangePasswordAtLogon = $true
            Enabled               = $true
            PassThru              = $true
            Confirm               = $false
            ErrorAction           = 'Stop'
        }
        foreach ($key in $connection.Keys) {
            $newUserParams[$key] = $connection[$key]
        }
        if ($managerDn) {
            $newUserParams['Manager'] = $managerDn
        }

        try {
            $created = New-ADUser @newUserParams
        } catch {
            # New-ADUser adds the object first and sets the password second; if the second step
            # fails (e.g. a stricter fine-grained password policy) a disabled account is left.
            $message = "Failed to create user '{0}' (check whether a disabled account was left behind): {1}" -f $sam, $_.Exception.Message
            Write-Error -Message $message -Category WriteError -TargetObject $sam
            return
        }

        # Past this point the account exists: always return the result, since it carries the password.
        $result.InitialPassword = $password
        $result.Applied = $true
        $member = $sam
        if ($created -and $created.DistinguishedName) {
            $member = [string]$created.DistinguishedName
            $result.DistinguishedName = $member
        }

        # Group failures are warnings, not errors, on purpose: with -ErrorAction Stop (or
        # $ErrorActionPreference = 'Stop') an error here would terminate the pipeline and the
        # only copy of the initial password would be lost. They are listed in FailedGroups.
        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($group in $groups) {
            try {
                Add-ADGroupMember -Identity $group -Members $member -Confirm:$false -ErrorAction Stop @connection
            } catch {
                $failed.Add($group)
                Write-Warning ("User '{0}' was created, but adding it to group '{1}' failed: {2}" -f $sam, $group, $_.Exception.Message)
            }
        }
        $result.FailedGroups = $failed.ToArray()

        $result
    }
}
