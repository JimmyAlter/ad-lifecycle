BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Disable-AdLifecycleUser' {
    BeforeAll {
        $userDn = 'CN=Lucía Muñoz,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        $disabledOu = 'OU=Disabled Users,OU=Corp,DC=corp,DC=example'
        $leaver = @{ Identity = 'lmunoz'; Ticket = 'INC-4821'; ConfigPath = $ExampleConfigPath }

        $domainUsers = New-TestAdGroup -Name 'Domain Users' -Rid 513
        $groupsToRemove = @(
            New-TestAdGroup -Name 'GG-All-Staff' -Rid 1101
            New-TestAdGroup -Name 'GG-Finance' -Rid 1102
            New-TestAdGroup -Name 'GG-Compañía-Read' -Rid 1103
        )
        $contractors = New-TestAdGroup -Name 'GG-Contractors' -Rid 1150
        $knownGroups = @($domainUsers, $contractors) + $groupsToRemove

        # Domain Users is the primary group, so memberOf does not list it.
        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'lmunoz' } -MockWith {
            New-TestAdUser -SamAccountName 'lmunoz' -DistinguishedName $userDn -MemberOf $groupsToRemove.DistinguishedName -Property @{
                Description = 'Accountant'
            }
        }
        # Groups by SID (<domain SID>-<RID>), as the leaver resolves the primary group and Domain Users.
        Mock Get-ADGroup -ModuleName AdLifecycle -MockWith {
            $knownGroups | Where-Object { $_.SID -eq $Identity }
        }
        Mock Get-Date -ModuleName AdLifecycle -MockWith { [datetime]::new(2026, 1, 31, 9, 30, 0) }
    }

    Context 'parameters' {
        It 'makes -Ticket mandatory' {
            $parameter = (Get-Command Disable-AdLifecycleUser).Parameters['Ticket']
            $attribute = $parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attribute.Mandatory | Should -BeTrue
        }

        It 'rejects the ticket <Ticket>' -ForEach @(
            @{ Ticket = '' }
            @{ Ticket = 'INC 4821' }
            @{ Ticket = 'INC-4821; rm -rf' }
            @{ Ticket = ('X' * 65) }
        ) {
            { Disable-AdLifecycleUser -Identity lmunoz -Ticket $Ticket -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'safety guard' {
        BeforeAll {
            $adminDn = 'CN=Administrator,CN=Users,DC=corp,DC=example'
            function Invoke-GuardedLeaver {
                param([hashtable]$Extra = @{})
                Invoke-Captured { Disable-AdLifecycleUser -Identity target1 -Ticket 'INC-9' -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue @Extra }
            }
        }

        It 'refuses <Account> (RID <Rid>) even with -Force' -ForEach @(
            @{ Account = 'the built-in Administrator'; Rid = 500; Message = '*built-in Administrator account (RID 500)*' }
            @{ Account = 'krbtgt'; Rid = 502; Message = '*krbtgt account (RID 502)*' }
        ) {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'renamed-account' -DistinguishedName $adminDn -Rid $Rid
            }

            $run = Invoke-GuardedLeaver -Extra @{ Force = $true }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "Refusing to offboard 'renamed-account': $Message"
            $run.Errors[0].CategoryInfo.Category | Should -Be 'PermissionDenied'
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'refuses the account running the command' {
            Mock Get-AdLifecycleCallerSid -ModuleName AdLifecycle -MockWith { "$TestDomainSid-1700" }
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'it.admin' -DistinguishedName 'CN=IT Admin,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1700
            }

            $run = Invoke-GuardedLeaver -Extra @{ Force = $true }

            "$($run.Errors[0])" | Should -BeLike "*'it.admin': it is the account running this command*"
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        Context '-Credential account' {
            BeforeAll {
                # sAMAccountName svc-prov, UPN provisioning@corp.example: the UPN prefix is not the
                # sAMAccountName, which a name comparison would miss.
                $serviceAccount = New-TestAdUser -SamAccountName 'svc-prov' -DistinguishedName 'CN=svc-prov,OU=Service,OU=Corp,DC=corp,DC=example' -Rid 1701
            }

            BeforeEach {
                Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith { $serviceAccount }
                Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $LDAPFilter -like '*(userPrincipalName=provisioning@corp.example)*' } -MockWith { $serviceAccount }
                Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $LDAPFilter -like '*(sAMAccountName=svc-prov)*' } -MockWith { $serviceAccount }
            }

            It 'refuses the -Credential account given as <UserName>' -ForEach @(
                @{ UserName = 'provisioning@corp.example'; Filter = '*(userPrincipalName=provisioning@corp.example)*' }
                @{ UserName = 'CORP\svc-prov'; Filter = '*(sAMAccountName=svc-prov)*' }
                @{ UserName = 'svc-prov'; Filter = '*(sAMAccountName=svc-prov)*' }
                @{ UserName = 'svc-prov@corp.example'; Filter = '*(sAMAccountName=svc-prov)*' }
            ) {
                $credential = [pscredential]::new($UserName, [securestring]::new())

                $run = Invoke-GuardedLeaver -Extra @{ Credential = $credential }

                "$($run.Errors[0])" | Should -BeLike "*'svc-prov': it is the account running this command*"
                Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $LDAPFilter -like $Filter -and $Credential.UserName -eq $UserName -and $Server -eq $TestDomainController
                }
                Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
            }

            It 'resolves the credential once per run, not per user' {
                $credential = [pscredential]::new('provisioning@corp.example', [securestring]::new())

                @('lmunoz', 'lmunoz') | Disable-AdLifecycleUser -Ticket 'INC-9' -ConfigPath $ExampleConfigPath -Credential $credential -Confirm:$false | Out-Null

                Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $LDAPFilter -like '*userPrincipalName=*' }
                Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 2 -Exactly
            }

            It 'offboards another user when running with -Credential' {
                $credential = [pscredential]::new('provisioning@corp.example', [securestring]::new())

                $result = Disable-AdLifecycleUser @leaver -Credential $credential -Confirm:$false

                $result.Applied | Should -BeTrue
            }

            It 'refuses to start when the -Credential account cannot be found' {
                $credential = [pscredential]::new('ghost@corp.example', [securestring]::new())

                { Disable-AdLifecycleUser @leaver -Credential $credential -Confirm:$false } |
                    Should -Throw "*-Credential account 'ghost@corp.example' was not found*"
                Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'lmunoz' }
                Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
            }

            It 'refuses to start when the -Credential lookup fails' {
                Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $LDAPFilter -like '*(userPrincipalName=provisioning@corp.example)*' } -MockWith { throw 'The server is not operational' }
                $credential = [pscredential]::new('provisioning@corp.example', [securestring]::new())

                { Disable-AdLifecycleUser @leaver -Credential $credential -Confirm:$false } |
                    Should -Throw "*Could not look up the -Credential account*not operational*"
            }

            It 'escapes LDAP special characters in the credential name' {
                $credential = [pscredential]::new('a*b(c)@corp.example', [securestring]::new())

                { Disable-AdLifecycleUser @leaver -Credential $credential -Confirm:$false } | Should -Throw '*was not found*'
                Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $LDAPFilter -eq '(&(objectCategory=person)(objectClass=user)(userPrincipalName=a\2ab\28c\29@corp.example))'
                }
                Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $LDAPFilter -eq '(&(objectCategory=person)(objectClass=user)(sAMAccountName=a\2ab\28c\29))'
                }
            }
        }

        It 'refuses a member of <Group> without -Force (<Source>)' -ForEach @(
            @{ Group = 'Domain Admins'; Source = 'nested, tokenGroups'; Property = @{ tokenGroups = @('S-1-5-21-1004336348-1177238915-682003330-1105', 'S-1-5-21-1004336348-1177238915-682003330-512') } }
            @{ Group = 'Schema Admins'; Source = 'tokenGroups'; Property = @{ tokenGroups = @('S-1-5-21-1004336348-1177238915-682003330-518') } }
            @{ Group = 'Enterprise Admins'; Source = 'forest root domain SID'; Property = @{ tokenGroups = @('S-1-5-21-111-222-333-519') } }
            @{ Group = 'Administrators'; Source = 'BUILTIN'; Property = @{ tokenGroups = @('S-1-5-32-544') } }
            @{ Group = 'Domain Admins'; Source = 'primary group'; Property = @{ PrimaryGroupID = 512 } }
            @{ Group = 'Domain Admins'; Source = 'memberOf, no tokenGroups'; Property = @{ MemberOf = @('CN=Domain Admins,CN=Users,DC=corp,DC=example') } }
        ) {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'ops.admin' -DistinguishedName 'CN=Ops Admin,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1703 -Property $Property
            }

            $run = Invoke-GuardedLeaver

            "$($run.Errors[0])" | Should -BeLike "*'ops.admin': it is a member of $Group; review it and use -Force*"
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'offboards a member of Domain Admins with -Force' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'ops.admin' -DistinguishedName 'CN=Ops Admin,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1703 `
                    -Property @{ tokenGroups = @("$TestDomainSid-512") }
            }

            $run = Invoke-GuardedLeaver -Extra @{ Force = $true }

            $run.Errors | Should -BeNullOrEmpty
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'does not treat ordinary groups with RIDs ending in 512 as privileged' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'plain1' -DistinguishedName 'CN=Plain One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1704 `
                    -Property @{ tokenGroups = @("$TestDomainSid-1512", "$TestDomainSid-5120") }
            }

            (Invoke-GuardedLeaver).Errors | Should -BeNullOrEmpty
        }

        It 'refuses an account with adminCount = 1 without -Force, also under -WhatIf' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'old.admin' -DistinguishedName 'CN=Old Admin,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1702 -Property @{ adminCount = 1 }
            }

            $run = Invoke-GuardedLeaver
            $whatIf = Invoke-Captured { Disable-AdLifecycleUser -Identity target1 -Ticket 'INC-9' -ConfigPath $ExampleConfigPath -WhatIf -ErrorAction Continue }

            "$($run.Errors[0])" | Should -BeLike "*'old.admin': adminCount is 1*use -Force*"
            $whatIf.Output | Should -BeNullOrEmpty
            $whatIf.Errors.Count | Should -Be 1
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'offboards an account with adminCount = 1 with -Force' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'old.admin' -DistinguishedName 'CN=Old Admin,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1702 -Property @{ adminCount = 1 }
            }

            $run = Invoke-GuardedLeaver -Extra @{ Force = $true }

            $run.Errors | Should -BeNullOrEmpty
            $run.Output[0].Applied | Should -BeTrue
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'reads adminCount and tokenGroups from AD' {
            Disable-AdLifecycleUser @leaver -WhatIf | Out-Null
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'adminCount' -and $Properties -contains 'tokenGroups'
            }
        }
    }

    Context 'with -WhatIf' {
        It 'performs zero write calls and writes no CSV' {
            $csv = Join-Path $TestDrive 'whatif.csv'

            Disable-AdLifecycleUser @leaver -ExportPath $csv -WhatIf | Out-Null

            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
            $csv | Should -Not -Exist
        }

        It 'returns the plan' {
            $plan = Disable-AdLifecycleUser @leaver -WhatIf

            $plan.PSObject.TypeNames | Should -Contain 'AdLifecycle.LeaverResult'
            $plan.Applied | Should -BeFalse
            $plan.PreviousGroups | Should -Be @('Domain Users', 'GG-All-Staff', 'GG-Finance', 'GG-Compañía-Read')
            $plan.KeptGroups | Should -Be @('Domain Users')
            $plan.RemovedGroups | Should -Be @('GG-All-Staff', 'GG-Finance', 'GG-Compañía-Read')
            $plan.TargetOU | Should -Be $disabledOu
            $plan.Description | Should -BeLike 'Disabled 2026-01-31 by * - ticket INC-4821'
        }
    }

    Context '-ResetPassword' {
        It 'resets the password to a random 64-character value after disabling, and does not return it' {
            $script:order = [System.Collections.Generic.List[string]]::new()
            $script:resetTo = $null
            Mock Disable-ADAccount -ModuleName AdLifecycle -MockWith { $script:order.Add('disable') }
            Mock Set-ADAccountPassword -ModuleName AdLifecycle -MockWith {
                $script:order.Add('reset')
                $script:resetTo = ConvertFrom-TestSecureString $NewPassword
            }

            $result = Disable-AdLifecycleUser @leaver -ResetPassword -Confirm:$false

            $result.PasswordReset | Should -BeTrue
            @($script:order) | Should -Be @('disable', 'reset')
            $script:resetTo.Length | Should -Be 64
            Should -Invoke Set-ADAccountPassword -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $Reset -and $NewPassword -is [securestring] -and $Server -eq $TestDomainController
            }
            @($result.PSObject.Properties | Where-Object { "$($_.Value)" -like "*$script:resetTo*" }) |
                Should -BeNullOrEmpty -Because 'the new password is discarded'
        }

        It 'never logs the password, and records that it was reset' {
            $log = Join-Path $TestDrive 'reset.jsonl'
            $script:resetTo = $null
            Mock Set-ADAccountPassword -ModuleName AdLifecycle -MockWith { $script:resetTo = ConvertFrom-TestSecureString $NewPassword }

            Disable-AdLifecycleUser @leaver -ResetPassword -LogPath $log -Confirm:$false | Out-Null

            $text = Get-Content -LiteralPath $log -Raw
            $text | Should -Not -Match ([regex]::Escape($script:resetTo))
            ($text | ConvertFrom-Json).Changes.ResetPassword | Should -BeTrue
        }

        It 'shows the reset in the plan and does nothing under -WhatIf' {
            Mock Write-Verbose -ModuleName AdLifecycle -MockWith { }
            $plan = Disable-AdLifecycleUser @leaver -ResetPassword -WhatIf

            $plan.PasswordReset | Should -BeFalse
            Should -Invoke Set-ADAccountPassword -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'does not reset the password without -ResetPassword' {
            (Disable-AdLifecycleUser @leaver -Confirm:$false).PasswordReset | Should -BeFalse
            Should -Invoke Set-ADAccountPassword -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'reports a failed reset and carries on with the other steps' {
            Mock Set-ADAccountPassword -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -ResetPassword -Confirm:$false -ErrorAction Continue }

            $run.Output[0].Applied | Should -BeTrue
            $run.Output[0].PasswordReset | Should -BeFalse
            "$($run.Errors[0])" | Should -BeLike "*is disabled, but resetting its password failed: Access is denied"
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'does not reset the password when disabling fails' {
            Mock Disable-ADAccount -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $null = Invoke-Captured { Disable-AdLifecycleUser @leaver -ResetPassword -Confirm:$false -ErrorAction Continue }

            Should -Invoke Set-ADAccountPassword -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'with -Confirm:$false' {
        It 'disables the account' {
            Disable-AdLifecycleUser @leaver -Confirm:$false | Out-Null
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq $userDn }
        }

        It 'sets the description "Disabled yyyy-MM-dd by <operator> - ticket <id>"' {
            $result = Disable-AdLifecycleUser @leaver -Confirm:$false

            $pattern = '^Disabled 2026-01-31 by ([^\\ ]+\\)?{0} - ticket INC-4821$' -f [regex]::Escape([Environment]::UserName)
            $result.Description | Should -Match $pattern
            $result.PreviousDescription | Should -Be 'Accountant'
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $Description -eq $result.Description
            }
        }

        It 'removes every group except Domain Users' {
            Disable-AdLifecycleUser @leaver -Confirm:$false | Out-Null

            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times $groupsToRemove.Count -Exactly
            foreach ($group in $groupsToRemove) {
                Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq $group.DistinguishedName -and $Members -eq $userDn
                }
            }
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter {
                $Identity -eq $domainUsers.DistinguishedName
            }
        }

        It 'moves the account to the disabled OU from the configuration' {
            Disable-AdLifecycleUser @leaver -Confirm:$false | Out-Null
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $TargetPath -eq $disabledOu
            }
        }

        It 'records the memberships it removed in the result' {
            $result = Disable-AdLifecycleUser @leaver -Confirm:$false

            $result.Applied | Should -BeTrue
            $result.PreviousGroups | Should -Be @('Domain Users', 'GG-All-Staff', 'GG-Finance', 'GG-Compañía-Read')
            $result.RemovedGroups | Should -Be @('GG-All-Staff', 'GG-Finance', 'GG-Compañía-Read')
            $result.KeptGroups | Should -Be @('Domain Users')
            $result.FailedGroups | Should -BeNullOrEmpty
        }

        It 'exports every membership to CSV (UTF-8) before changing anything' {
            $csv = Join-Path $TestDrive 'leavers.csv'
            Mock Disable-ADAccount -ModuleName AdLifecycle -MockWith {
                # The record must already be on disk when the first write happens.
                if (-not (Test-Path -LiteralPath $csv)) { throw 'CSV was not written first' }
            }

            $result = Disable-AdLifecycleUser @leaver -ExportPath $csv -Confirm:$false

            $result.ExportPath | Should -Be $csv
            $rows = @(Import-Csv -Path $csv -Encoding UTF8)
            $rows.Count | Should -Be 4
            $rows.GroupName | Should -Be @('Domain Users', 'GG-All-Staff', 'GG-Finance', 'GG-Compañía-Read')
            ($rows | Where-Object Kept -EQ 'True').GroupName | Should -Be 'Domain Users'
            $rows | ForEach-Object {
                $_.SamAccountName | Should -Be 'lmunoz'
                $_.Ticket | Should -Be 'INC-4821'
                $_.RecordedAt | Should -Be '2026-01-31 09:30:00'
            }
        }

        It 'appends to an existing CSV for bulk leavers' {
            $csv = Join-Path $TestDrive 'bulk.csv'
            Disable-AdLifecycleUser @leaver -ExportPath $csv -Confirm:$false | Out-Null
            Disable-AdLifecycleUser @leaver -ExportPath $csv -Confirm:$false | Out-Null
            @(Import-Csv -Path $csv -Encoding UTF8).Count | Should -Be 8
        }

        It 'changes nothing when the CSV cannot be written' {
            $csv = Join-Path (Join-Path $TestDrive 'missing-folder') 'leavers.csv'

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -ExportPath $csv -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*Could not write the membership record*'lmunoz' was not changed*"
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'edge cases' {
        It 'sends every AD call to one pinned writable DC' {
            Disable-AdLifecycleUser @leaver -Confirm:$false | Out-Null

            Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 1 -Exactly
            foreach ($command in @($AdWriteCommandNames) + 'Get-ADUser') {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Server -ne $TestDomainController }
            }
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Server -eq $TestDomainController }
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Server -eq $TestDomainController }
        }

        It 'skips an account that is already disabled and in the disabled OU, with a warning' {
            $csv = Join-Path $TestDrive 'rerun.csv'
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'gone1' } -MockWith {
                New-TestAdUser -SamAccountName 'gone1' -DistinguishedName "CN=Gone One,$disabledOu" -Rid 1604 `
                    -MemberOf $groupsToRemove[0].DistinguishedName -Property @{ Enabled = $false; Description = 'Disabled 2025-11-02 by CORP\it.admin - ticket INC-1000' }
            }

            $result = Disable-AdLifecycleUser -Identity gone1 -Ticket 'INC-2000' -ConfigPath $ExampleConfigPath -ExportPath $csv -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue

            $result.Skipped | Should -BeTrue
            $result.Applied | Should -BeFalse
            $result.Description | Should -Be 'Disabled 2025-11-02 by CORP\it.admin - ticket INC-1000'
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*'gone1' is already disabled and in*skipped*"
            $csv | Should -Not -Exist
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'still offboards a disabled account that is not in the disabled OU yet' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'half1' } -MockWith {
                New-TestAdUser -SamAccountName 'half1' -DistinguishedName 'CN=Half One,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' -Rid 1605 `
                    -Property @{ Enabled = $false }
            }

            $result = Disable-AdLifecycleUser -Identity half1 -Ticket 'INC-2001' -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.Skipped | Should -BeFalse
            $result.Applied | Should -BeTrue
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'keeps a non-default primary group as well as Domain Users' {
            # With another primary group, Domain Users shows up in memberOf like any other group.
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'contractor1' } -MockWith {
                New-TestAdUser -SamAccountName 'contractor1' -DistinguishedName 'CN=Contractor One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example' `
                    -Rid 1602 -PrimaryGroupID 1150 -MemberOf $domainUsers.DistinguishedName, $groupsToRemove[1].DistinguishedName
            }

            $result = Disable-AdLifecycleUser -Identity contractor1 -Ticket 'RITM0012345' -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.KeptGroups | Should -Be @('GG-Contractors', 'Domain Users')
            $result.RemovedGroups | Should -Be @('GG-Finance')
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'keeps Domain Users by RID even when the name is localized' {
            $usuarios = New-TestAdGroup -Name 'Usuarios del dominio' -Rid 513
            Mock Get-ADGroup -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $usuarios.SID } -MockWith { $usuarios }

            $result = Disable-AdLifecycleUser @leaver -Confirm:$false

            $result.KeptGroups | Should -Be @('Usuarios del dominio')
            Should -Invoke Get-ADGroup -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq "$TestDomainSid-513" }
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter {
                $Identity -eq $usuarios.DistinguishedName
            }
        }

        It 'does not move an account that is already in the disabled OU' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'old1' } -MockWith {
                New-TestAdUser -SamAccountName 'old1' -DistinguishedName "CN=Old One,$disabledOu" -Rid 1603
            }
            Disable-AdLifecycleUser -Identity old1 -Ticket 'INC-1' -ConfigPath $ExampleConfigPath -Confirm:$false | Out-Null

            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 1 -Exactly
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'stops for that user when disabling fails' {
            Mock Disable-ADAccount -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike '*Failed to disable*no other changes were made*Access is denied'
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'changes nothing when the memberships cannot be read' {
            Mock Get-ADGroup -ModuleName AdLifecycle -MockWith { throw 'The server is not operational' }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike '*Could not read the group memberships*nothing was changed*not operational*'
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'reads memberships from memberOf and primaryGroupID, not Get-ADPrincipalGroupMembership' {
            Disable-AdLifecycleUser @leaver -WhatIf | Out-Null

            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'lmunoz' -and $Properties -contains 'MemberOf' -and $Properties -contains 'PrimaryGroupID'
            }
            Should -Invoke Get-ADGroup -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq "$TestDomainSid-513" }
        }

        It 'names memberOf groups after their RDN, unescaping special characters' {
            $odd = 'CN=GG-Sales\, Madrid \+ Remote,OU=Groups,OU=Corp,DC=corp,DC=example'
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'lmunoz' } -MockWith {
                New-TestAdUser -SamAccountName 'lmunoz' -DistinguishedName $userDn -MemberOf $odd
            }

            $result = Disable-AdLifecycleUser @leaver -Confirm:$false

            $result.RemovedGroups | Should -Be @('GG-Sales, Madrid + Remote')
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq $odd }
        }

        It 'changes nothing when the primary group cannot be resolved' {
            Mock Get-ADGroup -ModuleName AdLifecycle -MockWith { }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            "$($run.Errors[0])" | Should -BeLike '*Could not read the group memberships*RID 513 was not found*'
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'changes nothing when the user SID is not a domain SID' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'lmunoz' } -MockWith {
                New-TestAdUser -SamAccountName 'lmunoz' -DistinguishedName $userDn -Property @{ SID = 'S-1-5-32-544' }
            }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            "$($run.Errors[0])" | Should -BeLike "*Unexpected SID 'S-1-5-32-544'*"
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'reports a failed description update or move but still returns the result' {
            Mock Set-ADUser -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }
            Mock Move-ADObject -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            $run.Output[0].Applied | Should -BeTrue
            $run.Errors.Count | Should -Be 2
            "$($run.Errors[0])" | Should -BeLike '*is disabled, but setting the description failed*'
            "$($run.Errors[1])" | Should -BeLike '*is disabled, but moving it to*failed*'
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times $groupsToRemove.Count -Exactly
        }

        It 'reports a failed group removal and carries on with the rest' {
            Mock Remove-ADGroupMember -ModuleName AdLifecycle -ParameterFilter { $Identity -like 'CN=GG-Finance,*' } -MockWith {
                throw 'Insufficient access rights'
            }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }
            $result = $run.Output[0]

            $result.Applied | Should -BeTrue
            $result.FailedGroups | Should -Be @('GG-Finance')
            $result.RemovedGroups | Should -Be @('GG-All-Staff', 'GG-Compañía-Read')
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*removing it from group 'GG-Finance' failed*"
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'writes an error and changes nothing for an unknown user' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'ghost' } -MockWith {
                throw "Cannot find an object with identity: 'ghost'"
            }

            $run = Invoke-Captured {
                Disable-AdLifecycleUser -Identity ghost -Ticket 'INC-1' -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*User 'ghost' was not found*"
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'treats a lookup that returns nothing as not found' {
            $run = Invoke-Captured {
                Disable-AdLifecycleUser -Identity nobody -Ticket 'INC-1' -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            "$($run.Errors[0])" | Should -BeLike "*User 'nobody' was not found*"
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'takes users and tickets from the pipeline (Import-Csv rows)' {
            $rows = @(
                [pscustomobject]@{ SamAccountName = 'lmunoz'; Ticket = 'INC-1' }
                [pscustomobject]@{ SamAccountName = 'lmunoz'; Ticket = 'INC-2' }
            )
            $results = $rows | Disable-AdLifecycleUser -ConfigPath $ExampleConfigPath -Confirm:$false

            $results.Ticket | Should -Be @('INC-1', 'INC-2')
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 2 -Exactly
        }
    }
}
