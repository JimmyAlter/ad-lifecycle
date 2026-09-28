BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock

    function Read-AuditLog {
        param([string]$Path)
        @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Audit log' {
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
        $disabledOu = 'OU=Disabled Users,OU=Corp,DC=corp,DC=example'
        $leaverDn = "CN=Lucía Muñoz,$madridOu"
        $domainUsers = New-TestAdGroup -Name 'Domain Users' -Rid 513
        $finance = New-TestAdGroup -Name 'GG-Finance' -Rid 1102

        Mock New-ADUser -ModuleName AdLifecycle -MockWith {
            [pscustomobject]@{ SamAccountName = $SamAccountName; DistinguishedName = "CN=$Name,$Path" }
        }
        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'lmunoz' } -MockWith {
            New-TestAdUser -SamAccountName 'lmunoz' -DistinguishedName $leaverDn -MemberOf $finance.DistinguishedName `
                -Property @{ Department = 'Finance'; Title = 'Accountant'; Office = 'Madrid' }
        }
        Mock Get-ADGroup -ModuleName AdLifecycle -MockWith {
            if ($Identity -eq $domainUsers.SID) {
                $domainUsers
            } else {
                [pscustomobject]@{ Name = $Identity; SamAccountName = $Identity; DistinguishedName = "CN=$Identity,OU=Groups,OU=Corp,DC=corp,DC=example" }
            }
        }
    }

    Context 'joiner' {
        It 'appends one JSON line per created user with the planned changes and the result' {
            $log = Join-Path $TestDrive 'joiner.jsonl'

            New-AdLifecycleUser @joiner -Ticket 'RITM0001' -LogPath $log -Confirm:$false | Out-Null
            New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false | Out-Null

            $entries = @(Read-AuditLog $log)
            $entries.Count | Should -Be 2
            $first = $entries[0]
            $first.Command | Should -Be 'New-AdLifecycleUser'
            $first.Target | Should -Be 'lmunoz'
            $first.DistinguishedName | Should -Be "CN=Lucía Muñoz,$madridOu"
            $first.Ticket | Should -Be 'RITM0001'
            $first.Applied | Should -BeTrue
            $first.Server | Should -Be $TestDomainController
            $first.Operator | Should -BeLike "*$([Environment]::UserName)"
            $first.TimestampUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
            $first.Changes.UserPrincipalName | Should -Be 'lmunoz@corp.example'
            $first.Changes.OU | Should -Be $madridOu
            $first.Changes.Groups | Should -Contain 'GG-Finance'
            @($first.FailedGroups).Count | Should -Be 0
            $entries[1].Target | Should -Be 'lmunoz'
            $entries[1].Ticket | Should -BeNullOrEmpty
        }

        It 'never writes the initial password' {
            $log = Join-Path $TestDrive 'nopassword.jsonl'

            $result = New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false
            $password = ConvertFrom-TestSecureString $result.InitialPassword

            Get-Content -LiteralPath $log -Raw | Should -Not -Match ([regex]::Escape($password))
            (Get-Content -LiteralPath $log -Raw) | Should -Not -Match 'Password'
        }

        It 'writes UTF-8 without a BOM' {
            $log = Join-Path $TestDrive 'encoding.jsonl'
            New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false | Out-Null

            $bytes = [System.IO.File]::ReadAllBytes($log)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Match 'Lucía Muñoz'
        }

        It 'records failed groups' {
            $log = Join-Path $TestDrive 'failedgroups.jsonl'
            Mock Add-ADGroupMember -ModuleName AdLifecycle -ParameterFilter { $Identity -eq 'GG-App-ERP' } -MockWith { throw 'Insufficient access rights' }

            New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false -WarningAction SilentlyContinue | Out-Null

            $entry = (Read-AuditLog $log)[0]
            $entry.Applied | Should -BeTrue
            $entry.FailedGroups | Should -Be @('GG-App-ERP')
            $entry.Errors[0] | Should -BeLike "*'GG-App-ERP' failed*"
        }

        It 'records a failed creation with Applied = false' {
            $log = Join-Path $TestDrive 'failedcreate.jsonl'
            Mock New-ADUser -ModuleName AdLifecycle -MockWith { throw 'The password does not meet the length, complexity, or history requirement' }

            $null = Invoke-Captured { New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false -ErrorAction Continue }

            $entry = (Read-AuditLog $log)[0]
            $entry.Applied | Should -BeFalse
            $entry.Errors[0] | Should -BeLike 'Failed to create user*'
        }

        It 'writes nothing under -WhatIf' {
            $log = Join-Path $TestDrive 'whatif.jsonl'
            New-AdLifecycleUser @joiner -LogPath $log -WhatIf | Out-Null
            $log | Should -Not -Exist
        }

        It 'takes the ticket from a CSV column' {
            $log = Join-Path $TestDrive 'csvticket.jsonl'
            $row = [pscustomobject]@{ GivenName = 'Luis'; Surname = 'Diaz'; Department = 'IT'; Site = 'Remote'; Title = 'Engineer'; Ticket = 'RITM0042' }

            $row | New-AdLifecycleUser -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false | Out-Null

            (Read-AuditLog $log)[0].Ticket | Should -Be 'RITM0042'
        }

        It 'uses LogPath from the configuration when -LogPath is not given' {
            $log = Join-Path $TestDrive 'fromconfig.jsonl'
            $config = Join-Path $TestDrive 'withlog.psd1'
            (Get-Content -Path $ExampleConfigPath -Raw) -replace 'PasswordLength = 16', ("PasswordLength = 16`r`n    LogPath = '{0}'" -f $log) |
                Set-Content -Path $config -Encoding UTF8
            $params = $joiner.Clone()
            $params.ConfigPath = $config

            New-AdLifecycleUser @params -Confirm:$false | Out-Null

            @(Read-AuditLog $log).Count | Should -Be 1
        }

        It 'refuses to start when the log folder does not exist' {
            $log = Join-Path (Join-Path $TestDrive 'no-such-folder') 'audit.jsonl'

            { New-AdLifecycleUser @joiner -LogPath $log -Confirm:$false } | Should -Throw '*folder of the audit log*does not exist*'
            Should -Invoke New-ADUser -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }

    Context 'mover' {
        It 'logs the group diff, attributes, move and ticket' {
            $log = Join-Path $TestDrive 'mover.jsonl'

            Set-AdLifecycleUser -Identity lmunoz -Department Sales -Site Cordoba -Title 'Account Executive' -Ticket 'CHG-77' `
                -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false | Out-Null

            $entry = (Read-AuditLog $log)[0]
            $entry.Command | Should -Be 'Set-AdLifecycleUser'
            $entry.Ticket | Should -Be 'CHG-77'
            $entry.Applied | Should -BeTrue
            $entry.Changes.FromDepartment | Should -Be 'Finance'
            $entry.Changes.AddGroups | Should -Contain 'GG-Sales'
            $entry.Changes.RemoveGroups | Should -Be @('GG-Finance')
            $entry.Changes.Attributes.Title | Should -Be 'Account Executive'
            $entry.Changes.Attributes.Office | Should -Be 'Cordoba'
            $entry.Changes.MoveTo | Should -Be 'OU=Users,OU=Cordoba,OU=Sites,OU=Corp,DC=corp,DC=example'
        }

        It 'writes nothing when there is nothing to change' {
            $log = Join-Path $TestDrive 'mover-noop.jsonl'
            Set-AdLifecycleUser -Identity lmunoz -Title Accountant -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false | Out-Null
            $log | Should -Not -Exist
        }
    }

    Context 'leaver' {
        It 'logs the ticket, the planned changes and the result' {
            $log = Join-Path $TestDrive 'leaver.jsonl'

            Disable-AdLifecycleUser -Identity lmunoz -Ticket 'INC-4821' -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false | Out-Null

            $entry = (Read-AuditLog $log)[0]
            $entry.Command | Should -Be 'Disable-AdLifecycleUser'
            $entry.Target | Should -Be 'lmunoz'
            $entry.DistinguishedName | Should -Be $leaverDn
            $entry.Ticket | Should -Be 'INC-4821'
            $entry.Applied | Should -BeTrue
            $entry.Changes.Disable | Should -BeTrue
            $entry.Changes.Description | Should -BeLike '*ticket INC-4821'
            $entry.Changes.RemoveGroups | Should -Be @('GG-Finance')
            $entry.Changes.KeptGroups | Should -Be @('Domain Users')
            $entry.Changes.MoveTo | Should -Be $disabledOu
        }

        It 'logs a failed disable with Applied = false' {
            $log = Join-Path $TestDrive 'leaver-failed.jsonl'
            Mock Disable-ADAccount -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            $null = Invoke-Captured { Disable-AdLifecycleUser -Identity lmunoz -Ticket 'INC-1' -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false -ErrorAction Continue }

            $entry = (Read-AuditLog $log)[0]
            $entry.Applied | Should -BeFalse
            $entry.Errors[0] | Should -BeLike 'Failed to disable*Access is denied'
        }

        It 'still logs when -ErrorAction Stop turns a later failure into a terminating error' {
            $log = Join-Path $TestDrive 'leaver-stop.jsonl'
            Mock Move-ADObject -ModuleName AdLifecycle -MockWith { throw 'Access is denied' }

            { Disable-AdLifecycleUser -Identity lmunoz -Ticket 'INC-2' -ConfigPath $ExampleConfigPath -LogPath $log -Confirm:$false -ErrorAction Stop } |
                Should -Throw '*moving it to*failed*'

            $entry = (Read-AuditLog $log)[0]
            $entry.Applied | Should -BeTrue
            $entry.Errors[0] | Should -BeLike '*moving it to*failed*'
        }

        It 'records the -Credential user' {
            $log = Join-Path $TestDrive 'leaver-cred.jsonl'
            $credential = [pscredential]::new('CORP\svc-lifecycle', [securestring]::new())

            Disable-AdLifecycleUser -Identity lmunoz -Ticket 'INC-3' -ConfigPath $ExampleConfigPath -LogPath $log -Credential $credential -Confirm:$false | Out-Null

            (Read-AuditLog $log)[0].CredentialUser | Should -Be 'CORP\svc-lifecycle'
        }
    }

    Context 'helpers' {
        It 'Resolve-AdLifecycleLogPath returns nothing when no log is configured' {
            InModuleScope AdLifecycle { Resolve-AdLifecycleLogPath -Config @{} } | Should -BeNullOrEmpty
        }

        It 'Resolve-AdLifecycleLogPath prefers -LogPath over the configuration' {
            $fromParam = Join-Path $TestDrive 'param.jsonl'
            $resolved = InModuleScope AdLifecycle -Parameters @{ P = $fromParam; C = (Join-Path $TestDrive 'config.jsonl') } {
                param($P, $C)
                Resolve-AdLifecycleLogPath -LogPath $P -Config @{ LogPath = $C }
            }
            $resolved | Should -Be $fromParam
        }

        It 'Resolve-AdLifecycleLogPath refuses a folder' {
            { InModuleScope AdLifecycle -Parameters @{ P = $TestDrive } { param($P) Resolve-AdLifecycleLogPath -LogPath $P } } |
                Should -Throw '*is a folder*'
        }

        It 'a log that cannot be written is a warning, not an error' {
            $warnings = InModuleScope AdLifecycle -Parameters @{ P = $TestDrive } {
                param($P)
                Write-AdLifecycleAuditLog -Path $P -Command 'Test' -Target 'x' -Applied $true 3>&1
            }
            "$warnings" | Should -BeLike "Could not write the audit log entry for 'x'*"
        }
    }
}
