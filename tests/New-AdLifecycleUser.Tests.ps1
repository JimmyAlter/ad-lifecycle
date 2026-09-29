BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'New-AdLifecycleUser' {
    BeforeAll {
        $joiner = @{
            GivenName  = 'Lucía'
            Surname    = 'Muñoz'
            Department = 'Finance'
            Site       = 'Madrid'
            Title      = 'Accountant'
            ConfigPath = $ExampleConfigPath
        }
        $madridOu = 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        $financeGroups = @('GG-All-Staff', 'GG-VPN-Users', 'GG-Finance', 'GG-Share-Finance-RW', 'GG-App-ERP', 'GG-Reporting-Read')
        $newUserDn = "CN=Lucía Muñoz,$madridOu"
    }

    Context 'with -WhatIf' {
        It 'performs zero write calls' {
            New-AdLifecycleUser @joiner -WhatIf | Out-Null

            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'returns the plan: sAMAccountName, UPN, OU and groups, without a password' {
            $plan = New-AdLifecycleUser @joiner -WhatIf

            $plan.PSObject.TypeNames | Should -Contain 'AdLifecycle.NewUserResult'
            $plan.SamAccountName | Should -BeExactly 'lmunoz'
            $plan.UserPrincipalName | Should -BeExactly 'lmunoz@corp.example'
            $plan.DisplayName | Should -BeExactly 'Lucía Muñoz'
            $plan.OU | Should -Be $madridOu
            $plan.Groups | Should -Be $financeGroups
            $plan.InitialPassword | Should -BeNullOrEmpty
            $plan.Applied | Should -BeFalse
        }

        It 'still runs the read-only collision check so the plan shows the real name' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $LDAPFilter -like '*(sAMAccountName=lmunoz)*' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'lmunoz' }
            }
            (New-AdLifecycleUser @joiner -WhatIf).SamAccountName | Should -BeExactly 'lmunoz2'
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'does not hand out the same name twice in one pipeline run' {
            $rows = @(
                [pscustomobject]@{ GivenName = 'Lucía'; Surname = 'Muñoz'; Department = 'Finance'; Site = 'Madrid'; Title = 'Accountant' }
                [pscustomobject]@{ GivenName = 'Luis'; Surname = 'Muñoz'; Department = 'Sales'; Site = 'Cordoba'; Title = 'Sales Rep' }
            )
            $plans = $rows | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -WhatIf
            $plans.SamAccountName | Should -Be @('lmunoz', 'lmunoz2')
        }

        It 'plans the example CSV of new hires' {
            $csv = Join-Path (Join-Path $RepoRoot 'examples') 'new-hires.csv'
            $plans = Import-Csv -Path $csv -Encoding UTF8 | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -WhatIf
            $plans.SamAccountName | Should -Be @('lmunoz', 'jpena', 'agomez', 'mfernandezcastellano')
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'with -Confirm:$false' {
        BeforeAll {
            Mock New-ADUser -ModuleName AdLifecycle -MockWith {
                [pscustomobject]@{ SamAccountName = $SamAccountName; DistinguishedName = "CN=$Name,$Path" }
            }
        }

        It 'creates the user in the site OU with the expected names and attributes' {
            New-AdLifecycleUser @joiner -Confirm:$false | Out-Null

            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $SamAccountName -ceq 'lmunoz' -and
                $UserPrincipalName -ceq 'lmunoz@corp.example' -and
                $Path -eq $madridOu -and
                $Name -ceq 'Lucía Muñoz' -and
                $DisplayName -ceq 'Lucía Muñoz' -and
                $GivenName -ceq 'Lucía' -and
                $Surname -ceq 'Muñoz' -and
                $Department -eq 'Finance' -and
                $Title -eq 'Accountant' -and
                $Office -eq 'Madrid'
            }
        }

        It 'creates the account enabled, with must-change-password and a SecureString password' {
            New-AdLifecycleUser @joiner -Confirm:$false | Out-Null

            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Enabled -eq $true -and $ChangePasswordAtLogon -eq $true -and $AccountPassword -is [securestring]
            }
        }

        It 'adds the new user to CommonGroups and the department groups' {
            New-AdLifecycleUser @joiner -Confirm:$false | Out-Null

            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times $financeGroups.Count -Exactly
            foreach ($group in $financeGroups) {
                Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq $group -and $Members -eq $newUserDn
                }
            }
        }

        It 'returns the password that was set, as a SecureString only' {
            $result = New-AdLifecycleUser @joiner -Confirm:$false

            $result.Applied | Should -BeTrue
            $result.DistinguishedName | Should -Be $newUserDn
            $result.InitialPassword | Should -BeOfType [securestring]
            $expected = ConvertFrom-TestSecureString $result.InitialPassword
            $expected.Length | Should -Be 16
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                (ConvertFrom-TestSecureString $AccountPassword) -ceq $expected
            }
            @($result.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -ceq $expected }) |
                Should -BeNullOrEmpty -Because 'the password must not appear in plain text anywhere in the result'
        }

        It 'uses PasswordLength from the configuration' {
            $config = Join-Path $TestDrive 'long-passwords.psd1'
            (Get-Content -Path $ExampleConfigPath -Raw) -replace 'PasswordLength = 16', 'PasswordLength = 24' |
                Set-Content -Path $config
            $params = $joiner.Clone()
            $params.ConfigPath = $config

            (New-AdLifecycleUser @params -Confirm:$false).InitialPassword.Length | Should -Be 24
        }

        It 'resolves -Manager to a distinguished name' {
            $managerDn = 'CN=Marta Lopez,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'mlopez' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'mlopez'; DistinguishedName = $managerDn }
            }

            $result = New-AdLifecycleUser @joiner -Manager mlopez -Confirm:$false

            $result.Manager | Should -Be $managerDn
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Manager -eq $managerDn }
        }

        It 'uses the suffixed name for sAMAccountName and UPN on a collision' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter {
                $LDAPFilter -like '*(sAMAccountName=lmunoz)*' -or $LDAPFilter -like '*(sAMAccountName=lmunoz2)*'
            } -MockWith { [pscustomobject]@{ SamAccountName = 'taken' } }

            New-AdLifecycleUser @joiner -Confirm:$false | Out-Null

            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $SamAccountName -ceq 'lmunoz3' -and $UserPrincipalName -ceq 'lmunoz3@corp.example'
            }
        }

        It 'gives a suffixed joiner a distinct CN, "display name (sAMAccountName)", to avoid a duplicate CN' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $LDAPFilter -like '*(sAMAccountName=lmunoz)*' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'lmunoz' }
            }

            $result = New-AdLifecycleUser @joiner -Confirm:$false

            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Name -ceq 'Lucía Muñoz (lmunoz2)' -and $DisplayName -ceq 'Lucía Muñoz' -and $SamAccountName -ceq 'lmunoz2'
            }
            $result.DistinguishedName | Should -Be "CN=Lucía Muñoz (lmunoz2),$madridOu"
            $result.DisplayName | Should -Be 'Lucía Muñoz'
        }

        It 'keeps the plain CN when the sAMAccountName needed no suffix' {
            New-AdLifecycleUser @joiner -Confirm:$false | Out-Null
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Name -ceq 'Lucía Muñoz' }
        }

        It 'gives the second of two same-name joiners in one run a distinct CN' {
            $rows = @(
                [pscustomobject]@{ GivenName = 'Lucía'; Surname = 'Muñoz'; Department = 'Finance'; Site = 'Madrid'; Title = 'Accountant' }
                [pscustomobject]@{ GivenName = 'Lucía'; Surname = 'Muñoz'; Department = 'Sales'; Site = 'Madrid'; Title = 'Sales Rep' }
            )

            $results = $rows | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -Confirm:$false

            $results.DistinguishedName | Should -Be @("CN=Lucía Muñoz,$madridOu", "CN=Lucía Muñoz (lmunoz2),$madridOu")
        }

        It 'still returns the password when adding a group fails, even with -ErrorAction Stop' {
            Mock Add-ADGroupMember -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'GG-App-ERP' } -MockWith {
                throw 'Insufficient access rights to perform the operation'
            }

            $result = New-AdLifecycleUser @joiner -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warnings

            $result.Applied | Should -BeTrue
            $result.InitialPassword | Should -BeOfType [securestring]
            $result.FailedGroups | Should -Be @('GG-App-ERP')
            @($warnings).Count | Should -Be 1
            "$($warnings[0])" | Should -BeLike "*was created, but adding it to group 'GG-App-ERP' failed*"
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times $financeGroups.Count -Exactly
        }

        It 'reports a failed creation as an error and returns nothing' {
            Mock New-ADUser -ModuleName AdLifecycle -MockWith { throw 'The password does not meet the length, complexity, or history requirement' }

            $run = Invoke-Captured { New-AdLifecycleUser @joiner -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "Failed to create user 'lmunoz'*disabled account was left behind*"
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'domain controller pinning' {
        BeforeAll {
            Mock New-ADUser -ModuleName AdLifecycle -MockWith {
                [pscustomobject]@{ SamAccountName = $SamAccountName; DistinguishedName = "CN=$Name,$Path" }
            }
        }

        It 'discovers one writable DC per run and sends every AD call of the joiner to it' {
            $rows = @(
                [pscustomobject]@{ GivenName = 'Lucía'; Surname = 'Muñoz'; Department = 'Finance'; Site = 'Madrid'; Title = 'Accountant'; Manager = 'mlopez' }
                [pscustomobject]@{ GivenName = 'Luis'; Surname = 'Diaz'; Department = 'IT'; Site = 'Remote'; Title = 'Engineer'; Manager = '' }
            )
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'mlopez' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'mlopez'; DistinguishedName = 'CN=Marta Lopez,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' }
            }

            $rows | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -Confirm:$false | Out-Null

            Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Discover -and $Writable }
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 2 -Exactly -ParameterFilter { $Server -eq $TestDomainController }
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Server -ne $TestDomainController }
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Server -ne $TestDomainController }
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq 'mlopez' -and $Server -eq $TestDomainController }
        }

        It 'uses -Server and -Credential as given, without discovery' {
            $credential = [pscredential]::new('CORP\svc-lifecycle', [securestring]::new())

            New-AdLifecycleUser @joiner -Server dc07.corp.example -Credential $credential -Confirm:$false | Out-Null

            Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Server -eq 'dc07.corp.example' -and $Credential.UserName -eq 'CORP\svc-lifecycle'
            }
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times $financeGroups.Count -Exactly -ParameterFilter {
                $Server -eq 'dc07.corp.example' -and $Credential.UserName -eq 'CORP\svc-lifecycle'
            }
        }

        It 'refuses to start when no writable DC can be located' {
            Mock Get-ADDomainController -ModuleName AdLifecycle -MockWith { throw 'The server is not operational' }

            { New-AdLifecycleUser @joiner -Confirm:$false } | Should -Throw '*writable domain controller*'
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'input validation' {
        It 'rejects an unknown <Parameter> without writing anything' -ForEach @(
            @{ Parameter = 'Department'; Value = 'Marketing'; Message = "*Unknown department 'Marketing'*" }
            @{ Parameter = 'Site'; Value = 'Lisbon'; Message = "*Unknown site 'Lisbon'*" }
        ) {
            $params = $joiner.Clone()
            $params[$Parameter] = $Value

            $run = Invoke-Captured { New-AdLifecycleUser @params -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike $Message
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'does not create the user when the manager does not exist' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'ghost' } -MockWith {
                throw "Cannot find an object with identity: 'ghost'"
            }

            $run = Invoke-Captured { New-AdLifecycleUser @joiner -Manager ghost -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*Manager 'ghost' was not found*"
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'treats a manager lookup that returns nothing as not found' {
            $run = Invoke-Captured { New-AdLifecycleUser @joiner -Manager nobody -Confirm:$false -ErrorAction Continue }

            "$($run.Errors[0])" | Should -BeLike "*Manager 'nobody' was not found*"
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'carries on with the next pipeline row after a bad one' {
            $rows = @(
                [pscustomobject]@{ GivenName = 'Ana'; Surname = 'Gomez'; Department = 'Marketing'; Site = 'Madrid'; Title = 'Analyst' }
                [pscustomobject]@{ GivenName = 'Luis'; Surname = 'Diaz'; Department = 'IT'; Site = 'Remote'; Title = 'Engineer' }
            )

            $run = Invoke-Captured { $rows | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue }

            $run.Errors.Count | Should -Be 1
            $run.Output.SamAccountName | Should -Be @('ldiaz')
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'refuses to start with an invalid configuration' {
            $config = Join-Path $TestDrive 'broken.psd1'
            (Get-Content -Path $ExampleConfigPath -Raw) -replace "DisabledOU     = '[^']+'", "DisabledOU = 'Disabled'" |
                Set-Content -Path $config
            $params = $joiner.Clone()
            $params.ConfigPath = $config

            { New-AdLifecycleUser @params -Confirm:$false } | Should -Throw '*DisabledOU*'
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'fails with a clear error when the ActiveDirectory module is missing' {
            Mock Get-Command -ModuleName AdLifecycle -ParameterFilter { $Name -eq 'Get-ADUser' } -MockWith { }
            Mock Get-Module -ModuleName AdLifecycle -ParameterFilter { $Name -eq 'ActiveDirectory' } -MockWith { }

            { New-AdLifecycleUser @joiner -WhatIf } | Should -Throw '*ActiveDirectory PowerShell module (RSAT) is required*'
        }
    }
}
