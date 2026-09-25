BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Set-AdLifecycleDepartment' {
    BeforeAll {
        # Example config:
        #   Finance = GG-Finance, GG-Share-Finance-RW, GG-App-ERP, GG-Reporting-Read
        #   Sales   = GG-Sales,   GG-Share-Sales-RW,   GG-App-CRM, GG-Reporting-Read
        $userDn = 'CN=Jose Pena,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        $mover = @{ Identity = 'jpena'; Department = 'Sales'; ConfigPath = $ExampleConfigPath }
        $expectedAdded = @('GG-Sales', 'GG-Share-Sales-RW', 'GG-App-CRM')
        $expectedRemoved = @('GG-Finance', 'GG-Share-Finance-RW', 'GG-App-ERP')

        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'jpena' } -MockWith {
            [pscustomobject]@{ SamAccountName = 'jpena'; DistinguishedName = $userDn; Department = 'Finance' }
        }
        # jpena never got GG-App-ERP, so there is nothing to remove for that one.
        Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
            New-TestAdGroup -Name 'Domain Users' -Rid 513
            New-TestAdGroup -Name 'GG-All-Staff' -Rid 1101
            New-TestAdGroup -Name 'GG-Finance' -Rid 1102
            New-TestAdGroup -Name 'GG-Share-Finance-RW' -Rid 1104
            New-TestAdGroup -Name 'GG-Reporting-Read' -Rid 1105
        }
    }

    Context 'group diff' {
        It 'computes Added, Removed and Unchanged from the two department templates' {
            $plan = Set-AdLifecycleDepartment @mover -WhatIf

            $plan.PSObject.TypeNames | Should -Contain 'AdLifecycle.MoverResult'
            $plan.FromDepartment | Should -Be 'Finance'
            $plan.ToDepartment | Should -Be 'Sales'
            $plan.Added | Should -Be $expectedAdded
            $plan.Removed | Should -Be $expectedRemoved
            $plan.Unchanged | Should -Be @('GG-Reporting-Read')
            $plan.Applied | Should -BeFalse
        }

        It 'never touches CommonGroups' {
            $plan = Set-AdLifecycleDepartment @mover -WhatIf
            @($plan.Added) + @($plan.Removed) + @($plan.Unchanged) | Should -Not -Contain 'GG-All-Staff'
        }

        It 'uses -FromDepartment instead of the AD attribute when given' {
            $plan = Set-AdLifecycleDepartment -Identity jpena -Department Sales -FromDepartment IT -ConfigPath $ExampleConfigPath -WhatIf

            $plan.FromDepartment | Should -Be 'IT'
            $plan.Removed | Should -Be @('GG-IT', 'GG-Share-IT-RW', 'GG-App-Monitoring-RO')
            $plan.Unchanged | Should -BeNullOrEmpty
        }
    }

    Context 'with -WhatIf' {
        It 'performs zero write calls' {
            Set-AdLifecycleDepartment @mover -WhatIf | Out-Null

            foreach ($command in $AdWriteCommandNames) {
                Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
            }
        }
    }

    Context 'with -Confirm:$false' {
        It 'adds every group of the new department' {
            Set-AdLifecycleDepartment @mover -Confirm:$false | Out-Null

            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 3 -Exactly
            foreach ($group in $expectedAdded) {
                Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                    $Identity -eq $group -and $Members -eq $userDn
                }
            }
        }

        It 'removes only the old groups the user actually holds' {
            Set-AdLifecycleDepartment @mover -Confirm:$false | Out-Null

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

            $result = Set-AdLifecycleDepartment @params -Confirm:$false

            $result.Applied | Should -BeTrue
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $userDn -and $Department -ceq 'Sales'
            }
        }

        It 'skips groups the user already has' {
            Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
                New-TestAdGroup -Name 'GG-Finance' -Rid 1102
                New-TestAdGroup -Name 'GG-Sales' -Rid 1201
            }
            Set-AdLifecycleDepartment @mover -Confirm:$false | Out-Null

            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 2 -Exactly
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -eq 'GG-Sales' }
        }

        It 'reports a failed group change and carries on' {
            Mock Add-ADGroupMember -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'GG-App-CRM' } -MockWith {
                throw 'Insufficient access rights'
            }

            $run = Invoke-Captured { Set-AdLifecycleDepartment @mover -Confirm:$false -ErrorAction Continue }

            $run.Output[0].FailedGroups | Should -Be @('GG-App-CRM')
            $run.Output[0].Applied | Should -BeTrue
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*to group 'GG-App-CRM' failed*"
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 2 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 1 -Exactly
        }
    }

    Context 'nothing to do or invalid input' {
        It 'writes nothing when the user is already in the target department' {
            $result = Set-AdLifecycleDepartment -Identity jpena -Department Finance -ConfigPath $ExampleConfigPath -Confirm:$false

            $result.Applied | Should -BeFalse
            $result.Added | Should -BeNullOrEmpty
            $result.Removed | Should -BeNullOrEmpty
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'throws for an unknown target department before reading AD' {
            { Set-AdLifecycleDepartment -Identity jpena -Department Marketing -ConfigPath $ExampleConfigPath -Confirm:$false } |
                Should -Throw "*Unknown department 'Marketing'*"
            Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'refuses when the current department is not configured and -FromDepartment is not given' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'legacy1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'legacy1'; DistinguishedName = 'CN=Legacy One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'; Department = 'Accounting (old)' }
            }

            $run = Invoke-Captured {
                Set-AdLifecycleDepartment -Identity legacy1 -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike "*'Accounting (old)'*is not in the configuration*-FromDepartment*"
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'changes nothing when the memberships cannot be read' {
            Mock Get-ADPrincipalGroupMembership -ModuleName AdLifecycle -ParameterFilter { $Identity -eq $userDn } -MockWith {
                throw 'The server is not operational'
            }

            $run = Invoke-Captured { Set-AdLifecycleDepartment @mover -Confirm:$false -ErrorAction Continue }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike '*Could not read the group memberships*nothing was changed*'
            Should -Invoke Add-ADGroupMember -ModuleName AdLifecycle -Times 0 -Exactly
            Should -Invoke Set-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }

        It 'writes an error for an unknown user' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'ghost' } -MockWith {
                throw "Cannot find an object with identity: 'ghost'"
            }

            $run = Invoke-Captured {
                Set-AdLifecycleDepartment -Identity ghost -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            "$($run.Errors[0])" | Should -BeLike "*User 'ghost' was not found*"
        }

        It 'refuses when the user has no Department attribute and -FromDepartment is not given' {
            Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'blank1' } -MockWith {
                [pscustomobject]@{ SamAccountName = 'blank1'; DistinguishedName = 'CN=Blank One,OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'; Department = $null }
            }

            $run = Invoke-Captured {
                Set-AdLifecycleDepartment -Identity blank1 -Department Sales -ConfigPath $ExampleConfigPath -Confirm:$false -ErrorAction Continue
            }

            $run.Output | Should -BeNullOrEmpty
            $run.Errors.Count | Should -Be 1
            "$($run.Errors[0])" | Should -BeLike '*has no Department attribute*'
        }
    }
}
