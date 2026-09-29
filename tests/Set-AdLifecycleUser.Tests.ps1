BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Set-AdLifecycleUser (mover)' {
    BeforeAll {
        # Example config:
        #   Finance = GG-Finance, GG-Share-Finance-RW, GG-App-ERP, GG-Reporting-Read
        #   Sales   = GG-Sales,   GG-Share-Sales-RW,   GG-App-CRM, GG-Reporting-Read
        $userDn = 'CN=Jose Pena,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        $mover = @{ Identity = 'jpena'; Department = 'Sales'; ConfigPath = $ExampleConfigPath }
        $expectedAdded = @('GG-Sales', 'GG-Share-Sales-RW', 'GG-App-CRM')
        $expectedRemoved = @('GG-Finance', 'GG-Share-Finance-RW', 'GG-App-ERP')

        function Get-TestGroupDn {
            param([string[]]$Name)
            $Name | ForEach-Object { "CN=$_,OU=Groups,OU=Corp,DC=corp,DC=example" }
        }

        # jpena never got GG-App-ERP, so there is nothing to remove for that one.
        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'jpena' } -MockWith {
            New-TestAdUser -SamAccountName 'jpena' -DistinguishedName $userDn `
                -MemberOf (Get-TestGroupDn 'GG-All-Staff', 'GG-Finance', 'GG-Share-Finance-RW', 'GG-Reporting-Read') `
                -Property @{ Department = 'Finance' }
        }
        # Every template group exists; the mover resolves them by sAMAccountName.
        Mock Get-ADGroup -ModuleName AdLifecycle -MockWith {
            [pscustomobject]@{ Name = $Identity; SamAccountName = $Identity; DistinguishedName = (Get-TestGroupDn $Identity) }
        }
    }

    Context 'group diff' {
        It 'computes Added, Removed and Unchanged from the two department templates' {
            $plan = Set-AdLifecycleUser @mover -WhatIf

            $plan.PSObject.TypeNames | Should -Contain 'AdLifecycle.MoverResult'
            $plan.FromDepartment | Should -Be 'Finance'
            $plan.ToDepartment | Should -Be 'Sales'
            $plan.Added | Should -Be $expectedAdded
            $plan.Removed | Should -Be $expectedRemoved
            $plan.Unchanged | Should -Be @('GG-Reporting-Read')
            $plan.Applied | Should -BeFalse
        }

        It 'never touches CommonGroups' {
            $plan = Set-AdLifecycleUser @mover -WhatIf
            @($plan.Added) + @($plan.Removed) + @($plan.Unchanged) | Should -Not -Contain 'GG-All-Staff'
        }

        It 'uses -FromDepartment instead of the AD attribute when given' {
            $plan = Set-AdLifecycleUser -Identity jpena -Department Sales -FromDepartment IT -ConfigPath $ExampleConfigPath -WhatIf

            $plan.FromDepartment | Should -Be 'IT'
            $plan.Removed | Should -Be @('GG-IT', 'GG-Share-IT-RW', 'GG-App-Monitoring-RO')
            $plan.Unchanged | Should -BeNullOrEmpty
        }
    }

    Context 'with -WhatIf' {
        It 'performs zero write calls' {
            Set-AdLifecycleUser @mover -WhatIf | Out-Null

            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }
    }

    Context 'with -Confirm:$false' {
        It 'adds every group of the new department' {
            Set-AdLifecycleUser @mover -Confirm:$false | Out-Null

            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 3 -Exactly
            foreach ($group in $expectedAdded) {
                Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq $group -and $Members -eq $userDn
                }
            }
        }

        It 'removes only the old groups the user actually holds' {
            Set-AdLifecycleUser @mover -Confirm:$false | Out-Null

            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 2 -Exactly
            foreach ($group in 'GG-Finance', 'GG-Share-Finance-RW') {
                Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq $group -and $Members -eq $userDn
                }
            }
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'GG-App-ERP' }
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'GG-Reporting-Read' }
        }

        It 'updates the Department attribute with the configured spelling' {
            $params = $mover.Clone()
            $params.Department = 'sales'

            $result = Set-AdLifecycleUser @params -Confirm:$false

            $result.Applied | Should -BeTrue
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $Department -ceq 'Sales'
            }
        }

        It 'skips groups the user already has' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'jpena' } -MockWith {
                New-TestAdUser -SamAccountName 'jpena' -DistinguishedName $userDn -MemberOf (Get-TestGroupDn 'GG-Finance', 'GG-Sales') -Property @{ Department = 'Finance' }
            }
            Set-AdLifecycleUser @mover -Confirm:$false | Out-Null

            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 2 -Exactly
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'GG-Sales' }
        }

        It 'reports a failed group change and carries on' {
            Mock Add-ADGroupMember -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'GG-App-CRM' } -MockWith {
                throw 'Insufficient access rights'
            }

            $run = Invoke-Captured { Set-AdLifecycleUser @mover -Confirm:$false -ErrorAction Continue }

            $run.Output[0].FailedGroups | Should -Be @('GG-App-CRM')
            $run.Output[0].Applied | Should -BeTrue
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*to group 'GG-App-CRM' failed*"
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 2 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly
        }
    }

    Context 'backward compatibility' {
        It 'still works as Set-AdLifecycleDepartment (alias)' {
            $result = Set-AdLifecycleDepartment @mover -Confirm:$false

            $result.Applied | Should -BeTrue
            $result.ToDepartment | Should -Be 'Sales'
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 3 -Exactly
        }
    }

    Context 'site, title and manager' {
        BeforeAll {
            $cordobaOu = 'OU=Users,OU=Cordoba,OU=Sites,OU=Corp,DC=corp,DC=example'
            $managerDn = 'CN=Marta Lopez,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'mlopez' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'mlopez'; DistinguishedName = $managerDn }
            }
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'jpena' } -MockWith {
                New-TestAdUser -SamAccountName 'jpena' -DistinguishedName $userDn `
                    -MemberOf (Get-TestGroupDn 'GG-All-Staff', 'GG-Finance', 'GG-Share-Finance-RW', 'GG-Reporting-Read') `
                    -Property @{ Department = 'Finance'; Title = 'Accountant'; Office = 'Madrid'; Manager = $null }
            }
            $transfer = @{
                Identity   = 'jpena'
                Department = 'Sales'
                Site       = 'Cordoba'
                Title      = 'Account Executive'
                Manager    = 'mlopez'
                ConfigPath = $ExampleConfigPath
            }
        }

        It 'plans everything under a single confirmation' {
            $plan = Set-AdLifecycleUser @transfer -WhatIf

            $plan.Applied | Should -BeFalse
            $plan.Added | Should -Be $expectedAdded
            $plan.TargetOU | Should -Be $cordobaOu
            $plan.PreviousOU | Should -Be 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
            $plan.Title | Should -Be 'Account Executive'
            $plan.PreviousTitle | Should -Be 'Accountant'
            $plan.Manager | Should -Be $managerDn
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'applies groups, then one Set-ADUser for all attributes, then the move' {
            $script:order = [System.Collections.Generic.List[string]]::new()
            Mock Add-ADGroupMember -ModuleName AdLifecycle -MockWith { $script:order.Add('add') }
            Mock Remove-ADGroupMember -ModuleName AdLifecycle -MockWith { $script:order.Add('remove') }
            Mock Set-ADUser -ModuleName AdLifecycle -MockWith { $script:order.Add('set') }
            Mock Move-ADObject -ModuleName AdLifecycle -MockWith { $script:order.Add('move') }

            $result = Set-AdLifecycleUser @transfer -Confirm:$false

            $result.Applied | Should -BeTrue
            $result.DistinguishedName | Should -Be "CN=Jose Pena,$cordobaOu"
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $Department -ceq 'Sales' -and $Title -ceq 'Account Executive' -and
                $Manager -eq $managerDn -and $Office -ceq 'Cordoba'
            }
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $TargetPath -eq $cordobaOu -and $Server -eq $TestDomainController
            }
            @($script:order) | Should -Be @('add', 'add', 'add', 'remove', 'remove', 'set', 'move')
        }

        It 'changes only the title when only -Title is given' {
            $result = Set-AdLifecycleUser -Identity jpena -Title 'Senior Accountant' -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.Applied | Should -BeTrue
            $result.FromDepartment | Should -BeNullOrEmpty
            $result.Added | Should -BeNullOrEmpty
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Title -ceq 'Senior Accountant' -and $null -eq $Department -and $null -eq $Office
            }
            Should -Invoke Get-ADGroup -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Move-ADObject -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'writes nothing when the user already has the requested values' {
            $result = Set-AdLifecycleUser -Identity jpena -Site Madrid -Title Accountant -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.Applied | Should -BeFalse
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'reports a failed attribute update and a failed move, and keeps going' {
            Mock Set-ADUser -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }
            Mock Move-ADObject -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $run = Invoke-Captured { Set-AdLifecycleUser @transfer -Confirm:$false -ErrorAction Continue }

            $run.Output[0].Applied | Should -BeTrue
            $run.Output[0].DistinguishedName | Should -Be $userDn
            $run.Errors.Count | Should -Be 2
            "$($run.Errors[0])" | Should -BeLike "Setting Department, Manager, Office, Title of 'jpena' failed*"
            "$($run.Errors[1])" | Should -BeLike "Moving 'jpena' to '$cordobaOu' failed*"
        }

        It 'refuses to start without anything to change' {
            { Set-AdLifecycleUser -Identity jpena -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw '*Nothing to change*'
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'refuses an unknown site before reading AD' {
            { Set-AdLifecycleUser -Identity jpena -Site Lisbon -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw "*Unknown site 'Lisbon'*"
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'refuses a manager that does not exist, before touching any user (<Case>)' -ForEach @(
            @{ Case = 'lookup throws'; Behavior = { throw "Cannot find an object with identity: 'ghost'" } }
            @{ Case = 'lookup returns nothing'; Behavior = { } }
        ) {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'ghost' } -MockWith $Behavior

            { Set-AdLifecycleUser -Identity jpena -Manager ghost -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw "*Manager 'ghost' was not found*"
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'jpena' }
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'safety guard' {
        BeforeAll {
            $adminOu = 'CN=Users,DC=corp,DC=example'
        }

        It 'refuses <Account> even with -Force' -ForEach @(
            @{ Account = 'the built-in Administrator'; Rid = 500; Message = '*built-in Administrator account (RID 500)*' }
            @{ Account = 'krbtgt'; Rid = 502; Message = '*krbtgt account (RID 502)*' }
        ) {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'renamed' -DistinguishedName "CN=Renamed,$adminOu" -Rid $Rid -Property @{ Department = 'Finance' }
            }

            $run = Invoke-Captured {
                Set-AdLifecycleUser -Identity target1 -Department Sales -Site Cordoba -ConfigPath $ExampleConfigPath -Force -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike "Refusing to change 'renamed': $Message"
            $run.Errors[0].CategoryInfo.Category | Should -Be 'PermissionDenied'
            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }

        It 'refuses a protected account (<Case>) without -Force and changes it with -Force' -ForEach @(
            @{ Case = 'adminCount = 1'; Property = @{ adminCount = 1 }; Message = '*adminCount is 1*' }
            @{ Case = 'nested Domain Admins'; Property = @{ tokenGroups = @('S-1-5-21-1004336348-1177238915-682003330-512') }; Message = '*member of Domain Admins*' }
        ) {
            $userProperties = @{ Department = 'Finance' } + $Property
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'target1' } -MockWith {
                New-TestAdUser -SamAccountName 'ops.admin' -DistinguishedName "CN=Ops Admin,$adminOu" -Rid 1703 -Property $userProperties
            }

            $refused = Invoke-Captured { Set-AdLifecycleUser -Identity target1 -Title 'Lead' -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue }
            "$($refused.Errors[0])" | Should -BeLike "Refusing to change 'ops.admin': $Message"
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly

            $forced = Set-AdLifecycleUser -Identity target1 -Title 'Lead' -ConfigPath $ExampleConfigPath -Force -Confirm:$false
            $forced.Applied | Should -BeTrue
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly
        }

        It 'reads the attributes the guard needs' {
            Set-AdLifecycleUser @mover -WhatIf | Out-Null
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'adminCount' -and $Properties -contains 'tokenGroups' -and $Properties -contains 'PrimaryGroupID'
            }
        }
    }

    Context 'domain controller' {
        It 'uses -Server for every AD call' {
            Set-AdLifecycleUser @mover -Server dc07.corp.example -Confirm:$false | Out-Null

            Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 0 -Exactly
            foreach ($command in @($AdWriteCommandNames) + 'Get-ADUser') {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Server -ne 'dc07.corp.example' }
            }
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 3 -Exactly -ParameterFilter { $Server -eq 'dc07.corp.example' }
        }
    }

    Context 'nothing to do or invalid input' {
        It 'writes nothing when the user is already in the target department' {
            $result = Set-AdLifecycleUser -Identity jpena -Department Finance -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.Applied | Should -BeFalse
            $result.Added | Should -BeNullOrEmpty
            $result.Removed | Should -BeNullOrEmpty
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'throws for an unknown target department before reading AD' {
            { Set-AdLifecycleUser -Identity jpena -Department Marketing -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw "*Unknown department 'Marketing'*"
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'refuses when the current department is not configured and -FromDepartment is not given' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'legacy1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'legacy1'; DistinguishedName = 'CN=Legacy One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'; Department = 'Accounting (old)' }
            }

            $run = Invoke-Captured {
                Set-AdLifecycleUser -Identity legacy1 -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*'Accounting (old)'*is not in the configuration*-FromDepartment*"
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'changes nothing when a template group cannot be resolved (<Case>)' -ForEach @(
            @{ Case = 'lookup fails'; Behavior = { throw 'The server is not operational' }; Message = '*not operational*' }
            @{ Case = 'no such group'; Behavior = { }; Message = "*Group 'GG-App-CRM' was not found*" }
        ) {
            Mock Get-ADGroup -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'GG-App-CRM' } -MockWith $Behavior

            $run = Invoke-Captured { Set-AdLifecycleUser @mover -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike '*Could not resolve the template groups*nothing was changed*'
            "$($run.Errors[0])" | Should -BeLike $Message
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'compares memberships by DN from memberOf, not Get-ADPrincipalGroupMembership' {
            Set-AdLifecycleUser @mover -WhatIf | Out-Null

            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Properties -contains 'MemberOf' }
            Should -Invoke Get-ADGroup -ModuleName AdLifecycle -Times 6 -Exactly
        }

        It 'writes an error for an unknown user' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'ghost' } -MockWith {
                throw "Cannot find an object with identity: 'ghost'"
            }

            $run = Invoke-Captured {
                Set-AdLifecycleUser -Identity ghost -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike "*User 'ghost' was not found*"
        }

        It 'refuses when the user has no Department attribute and -FromDepartment is not given' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'blank1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'blank1'; DistinguishedName = 'CN=Blank One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'; Department = $null }
            }

            $run = Invoke-Captured {
                Set-AdLifecycleUser -Identity blank1 -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike '*has no Department attribute*'
        }
    }
}
