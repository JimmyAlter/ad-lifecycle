BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Get-AdStaleComputer' {
    BeforeAll {
        # Fixed "now" so the date math is deterministic.
        $now = [datetime]::new(2026, 1, 31, 12, 0, 0, [System.DateTimeKind]::Utc)
        Mock Get-Date -ModuleName AdLifecycle -MockWith { $now }

        # pwdLastSet defaults to the last logon (or, without one, the creation date), so only the
        # computers that set -PasswordDaysAgo / -RawPasswordLastSet exercise the second signal.
        function New-TestComputer {
            param([string]$Name, $LastLogonDaysAgo, [int]$CreatedDaysAgo = 1000, $RawLastLogon, $PasswordDaysAgo, $RawPasswordLastSet)
            $raw = $RawLastLogon
            if ($null -ne $LastLogonDaysAgo) {
                $raw = $now.AddDays(-$LastLogonDaysAgo).ToFileTimeUtc()
            }
            $rawPassword = $RawPasswordLastSet
            if ($null -eq $rawPassword) {
                if ($null -eq $PasswordDaysAgo) {
                    $PasswordDaysAgo = $CreatedDaysAgo
                    if ($null -ne $LastLogonDaysAgo) { $PasswordDaysAgo = $LastLogonDaysAgo }
                }
                $rawPassword = $now.AddDays(-$PasswordDaysAgo).ToFileTimeUtc()
            }
            [pscustomobject]@{
                Name               = $Name
                DistinguishedName  = "CN=$Name,OU=Workstations,OU=Corp,DC=corp,DC=example"
                Enabled            = $true
                OperatingSystem    = 'Windows 11 Pro'
                lastLogonTimestamp = $raw
                pwdLastSet         = $rawPassword
                whenCreated        = $now.AddDays(-$CreatedDaysAgo)
            }
        }

        $computers = @(
            New-TestComputer -Name 'PC-OLD' -LastLogonDaysAgo 200
            New-TestComputer -Name 'PC-RECENT' -LastLogonDaysAgo 10
            New-TestComputer -Name 'PC-91' -LastLogonDaysAgo 91
            New-TestComputer -Name 'PC-89' -LastLogonDaysAgo 89
            New-TestComputer -Name 'PC-NEVER-OLD' -CreatedDaysAgo 300
            New-TestComputer -Name 'PC-NEVER-NEW' -CreatedDaysAgo 5
            New-TestComputer -Name 'PC-ZERO' -RawLastLogon ([long]0) -CreatedDaysAgo 400
            # Old logon, but the machine changed its password 20 days ago: alive.
            New-TestComputer -Name 'PC-PWD-FRESH' -LastLogonDaysAgo 150 -PasswordDaysAgo 20
            # Never logged on, but a fresh password: alive (logon not replicated / not written).
            New-TestComputer -Name 'PC-NEVER-PWD-FRESH' -CreatedDaysAgo 300 -PasswordDaysAgo 5
        )
        Mock Get-ADComputer -ModuleName AdLifecycle -MockWith { $computers }
    }

    It 'returns only computers older than the threshold, plus old never-logged-on ones' {
        $stale = Get-AdStaleComputer -Days 90
        @($stale.Name | Sort-Object) | Should -Be @('PC-91', 'PC-NEVER-OLD', 'PC-OLD', 'PC-ZERO')
    }

    It 'converts lastLogonTimestamp from FILETIME to a UTC DateTime' {
        $old = Get-AdStaleComputer -Days 90 | Where-Object Name -EQ 'PC-OLD'

        $old.LastLogonUtc | Should -BeOfType [datetime]
        $old.LastLogonUtc.Kind | Should -Be 'Utc'
        $old.LastLogonUtc | Should -Be $now.AddDays(-200)
        $old.DaysInactive | Should -Be 200
        $old.NeverLoggedOn | Should -BeFalse
    }

    It 'converts a known FILETIME value exactly' {
        # 2025-06-01T00:00:00Z
        Mock Get-ADComputer -ModuleName AdLifecycle -MockWith {
            New-TestComputer -Name 'PC-KNOWN' -RawLastLogon ([long]133932096000000000)
        }
        $known = Get-AdStaleComputer -Days 30

        $known.LastLogonUtc | Should -Be ([datetime]::new(2025, 6, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $known.DaysInactive | Should -Be 244
    }

    It 'flags never-logged-on computers explicitly (missing attribute or 0)' {
        $never = @(Get-AdStaleComputer -Days 90 | Where-Object NeverLoggedOn)

        @($never.Name | Sort-Object) | Should -Be @('PC-NEVER-OLD', 'PC-ZERO')
        $never | ForEach-Object {
            $_.LastLogonUtc | Should -BeNullOrEmpty
            $_.DaysInactive | Should -BeNullOrEmpty
        }
    }

    It 'does not report never-logged-on computers created after the cutoff' {
        (Get-AdStaleComputer -Days 90).Name | Should -Not -Contain 'PC-NEVER-NEW'
    }

    It 'honours -Days' {
        @((Get-AdStaleComputer -Days 150).Name | Sort-Object) | Should -Be @('PC-NEVER-OLD', 'PC-OLD', 'PC-ZERO')
    }

    It 'asks AD only for candidates, with the cutoff as FILETIME on both attributes in the LDAP filter' {
        Get-AdStaleComputer -Days 90 | Out-Null

        $cutoff = $now.AddDays(-90).ToFileTimeUtc()
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
            $LDAPFilter -eq "(&(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<=$cutoff))(|(!(pwdLastSet=*))(pwdLastSet<=$cutoff)))" -and
            $Properties -contains 'lastLogonTimestamp' -and
            $Properties -contains 'pwdLastSet' -and
            $Properties -contains 'whenCreated'
        }
    }

    It 'with -LastLogonOnly, filters on lastLogonTimestamp alone' {
        Get-AdStaleComputer -Days 90 -LastLogonOnly | Out-Null

        $cutoff = $now.AddDays(-90).ToFileTimeUtc()
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
            $LDAPFilter -eq "(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<=$cutoff))"
        }
    }

    It 'does not report a computer whose machine password changed after the cutoff' {
        $names = (Get-AdStaleComputer -Days 90).Name
        $names | Should -Not -Contain 'PC-PWD-FRESH'
        $names | Should -Not -Contain 'PC-NEVER-PWD-FRESH'
    }

    It 'reports them with -LastLogonOnly (lastLogonTimestamp alone)' {
        $stale = Get-AdStaleComputer -Days 90 -LastLogonOnly
        @($stale.Name | Sort-Object) | Should -Be @('PC-91', 'PC-NEVER-OLD', 'PC-NEVER-PWD-FRESH', 'PC-OLD', 'PC-PWD-FRESH', 'PC-ZERO')
        ($stale | Where-Object Name -EQ 'PC-PWD-FRESH').DaysSincePasswordSet | Should -Be 20
    }

    It 'converts pwdLastSet to UTC and counts pwdLastSet = 0 as no password change' {
        Mock Get-ADComputer -ModuleName AdLifecycle -MockWith {
            New-TestComputer -Name 'PC-PWD-OLD' -LastLogonDaysAgo 120 -PasswordDaysAgo 130
            New-TestComputer -Name 'PC-PWD-ZERO' -LastLogonDaysAgo 120 -RawPasswordLastSet ([long]0)
        }
        $stale = Get-AdStaleComputer -Days 90

        $old = $stale | Where-Object Name -EQ 'PC-PWD-OLD'
        $old.PasswordLastSetUtc | Should -Be $now.AddDays(-130)
        $old.PasswordLastSetUtc.Kind | Should -Be 'Utc'
        $old.DaysSincePasswordSet | Should -Be 130
        $zero = $stale | Where-Object Name -EQ 'PC-PWD-ZERO'
        $zero.PasswordLastSetUtc | Should -BeNullOrEmpty
        $zero.DaysSincePasswordSet | Should -BeNullOrEmpty
    }

    It 'passes -SearchBase through' {
        $ou = 'OU=Workstations,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        Get-AdStaleComputer -SearchBase $ou | Out-Null
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $SearchBase -eq $ou }
    }

    It 'does not pass SearchBase when it is not given' {
        Get-AdStaleComputer | Out-Null
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $null -eq $SearchBase }
    }

    It 'passes -Server and -Credential through and does not discover a DC' {
        $credential = [pscredential]::new('CORP\svc-report', [securestring]::new())
        Get-AdStaleComputer -Server dc07.corp.example -Credential $credential | Out-Null

        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
            $Server -eq 'dc07.corp.example' -and $Credential.UserName -eq 'CORP\svc-report'
        }
        Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 0 -Exactly
    }

    It 'lets the AD module pick a DC when -Server is not given' {
        Get-AdStaleComputer | Out-Null
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $null -eq $Server -and $null -eq $Credential }
    }

    It 'returns typed objects with the documented properties' {
        $first = Get-AdStaleComputer | Select-Object -First 1
        $first.PSObject.TypeNames | Should -Contain 'AdLifecycle.StaleComputer'
        $first.PSObject.Properties.Name | Should -Be @(
            'Name', 'Enabled', 'OperatingSystem', 'LastLogonUtc', 'DaysInactive', 'NeverLoggedOn', 'PasswordLastSetUtc', 'DaysSincePasswordSet', 'WhenCreatedUtc', 'DistinguishedName'
        )
    }

    It 'never calls an AD write cmdlet' {
        Get-AdStaleComputer | Out-Null
        foreach ($command in $AdWriteCommandNames) {
            Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }
}
