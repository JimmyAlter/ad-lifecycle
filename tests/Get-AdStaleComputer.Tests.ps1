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

        function New-TestComputer {
            param([string]$Name, $LastLogonDaysAgo, [int]$CreatedDaysAgo = 1000, $RawLastLogon)
            $raw = $RawLastLogon
            if ($null -ne $LastLogonDaysAgo) {
                $raw = $now.AddDays(-$LastLogonDaysAgo).ToFileTimeUtc()
            }
            [pscustomobject]@{
                Name               = $Name
                DistinguishedName  = "CN=$Name,OU=Workstations,OU=Corp,DC=corp,DC=example"
                Enabled            = $true
                OperatingSystem    = 'Windows 11 Pro'
                lastLogonTimestamp = $raw
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

    It 'asks AD only for candidates, with the cutoff as FILETIME in the LDAP filter' {
        Get-AdStaleComputer -Days 90 | Out-Null

        $cutoff = $now.AddDays(-90).ToFileTimeUtc()
        Should -Invoke Get-ADComputer -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
            $LDAPFilter -eq "(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<=$cutoff))" -and
            $Properties -contains 'lastLogonTimestamp' -and
            $Properties -contains 'whenCreated'
        }
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

    It 'returns typed objects with the documented properties' {
        $first = Get-AdStaleComputer | Select-Object -First 1
        $first.PSObject.TypeNames | Should -Contain 'AdLifecycle.StaleComputer'
        $first.PSObject.Properties.Name | Should -Be @(
            'Name', 'Enabled', 'OperatingSystem', 'LastLogonUtc', 'DaysInactive', 'NeverLoggedOn', 'WhenCreatedUtc', 'DistinguishedName'
        )
    }

    It 'never calls an AD write cmdlet' {
        Get-AdStaleComputer | Out-Null
        foreach ($command in $AdWriteCommandNames) {
            Should -Invoke $command -ModuleName AdLifecycle -Times 0 -Exactly
        }
    }
}
