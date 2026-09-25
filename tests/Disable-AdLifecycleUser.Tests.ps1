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
        $memberships = @($domainUsers) + $groupsToRemove

        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'lmunoz' } -MockWith {
            [pscustomobject]@{
                SamAccountName    = 'lmunoz'
                DistinguishedName = $userDn
                PrimaryGroupID    = 513
                Description       = 'Accountant'
                Enabled           = $true
            }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
            $memberships
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
        It 'keeps a non-default primary group as well as Domain Users' {
            $contractors = New-TestAdGroup -Name 'GG-Contractors' -Rid 1150
            $finance = New-TestAdGroup -Name 'GG-Finance' -Rid 1102
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'contractor1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'contractor1'; DistinguishedName = 'CN=Contractor One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'; PrimaryGroupID = 1150 }
            }
            Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -like 'CN=Contractor One,*' } -MockWith {
                $contractors, $domainUsers, $finance
            }

            $result = Disable-AdLifecycleUser -Identity contractor1 -Ticket 'RITM0012345' -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.KeptGroups | Should -Be @('GG-Contractors', 'Domain Users')
            $result.RemovedGroups | Should -Be @('GG-Finance')
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'keeps Domain Users by RID even when the name is localized' {
            $usuarios = New-TestAdGroup -Name 'Usuarios del dominio' -Rid 513
            Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
                $usuarios, $groupsToRemove[0]
            }

            $result = Disable-AdLifecycleUser @leaver -Confirm:$false

            $result.KeptGroups | Should -Be @('Usuarios del dominio')
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter {
                $Identity -eq $usuarios.DistinguishedName
            }
        }

        It 'does not move an account that is already in the disabled OU' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'old1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'old1'; DistinguishedName = "CN=Old One,$disabledOu"; PrimaryGroupID = 513 }
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
            Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
                throw 'The server is not operational'
            }

            $run = Invoke-Captured { Disable-AdLifecycleUser @leaver -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike '*Could not read the group memberships*nothing was changed*'
            Should -Invoke Disable-ADAccount -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
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
