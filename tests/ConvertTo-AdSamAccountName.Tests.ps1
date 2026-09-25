BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'ConvertTo-AdSamAccountName' {
    It 'turns "<GivenName> <Surname>" into <Expected>' -ForEach @(
        @{ GivenName = 'Lucía'; Surname = 'Muñoz'; Expected = 'lmunoz' }
        @{ GivenName = 'José'; Surname = 'Peña'; Expected = 'jpena' }
        @{ GivenName = 'Ángel'; Surname = 'Gómez'; Expected = 'agomez' }
        @{ GivenName = 'Íñigo'; Surname = 'Ibáñez'; Expected = 'iibanez' }
        @{ GivenName = 'MARÍA JOSÉ'; Surname = 'NÚÑEZ'; Expected = 'mnunez' }
        @{ GivenName = 'Ana'; Surname = 'de la Fuente'; Expected = 'adelafuente' }
        @{ GivenName = 'Ana'; Surname = 'García-López'; Expected = 'agarcialopez' }
        @{ GivenName = 'Seán'; Surname = "O'Brien"; Expected = 'sobrien' }
        @{ GivenName = 'Joël'; Surname = 'Müller'; Expected = 'jmuller' }
        @{ GivenName = 'Jürgen'; Surname = 'Straße'; Expected = 'jstrasse' }
        @{ GivenName = 'Søren'; Surname = 'Kierkegaard'; Expected = 'skierkegaard' }
        @{ GivenName = 'Łukasz'; Surname = 'Wałęsa'; Expected = 'lwalesa' }
        @{ GivenName = '  Juan '; Surname = ' Pérez  '; Expected = 'jperez' }
    ) {
        $actual = InModuleScope AdLifecycle -Parameters @{ G = $GivenName; S = $Surname } {
            param($G, $S)
            ConvertTo-AdSamAccountName -GivenName $G -Surname $S
        }
        $actual | Should -BeExactly $Expected
    }

    It 'only ever produces lowercase a-z and 0-9' {
        $actual = InModuleScope AdLifecycle {
            ConvertTo-AdSamAccountName -GivenName 'Zoë-Ann' -Surname "D'Artagnan y Cía. (3rd)"
        }
        $actual | Should -MatchExactly '^[a-z0-9]+$'
    }

    It 'truncates to 20 characters' {
        $actual = InModuleScope AdLifecycle {
            ConvertTo-AdSamAccountName -GivenName 'Maximiliano' -Surname 'Fernández-Castellanos'
        }
        $actual | Should -BeExactly 'mfernandezcastellano'
        $actual.Length | Should -Be 20
    }

    It 'truncates the base, not the suffix, so the suffix always fits' {
        $actual = InModuleScope AdLifecycle {
            ConvertTo-AdSamAccountName -GivenName 'Maximiliano' -Surname 'Fernández-Castellanos' -Suffix 12
        }
        $actual | Should -BeExactly 'mfernandezcastella12'
        $actual.Length | Should -Be 20
    }

    It 'appends the suffix to short names unchanged' {
        InModuleScope AdLifecycle { ConvertTo-AdSamAccountName -GivenName 'Lucía' -Surname 'Muñoz' -Suffix 2 } |
            Should -BeExactly 'lmunoz2'
    }

    It 'throws when nothing usable is left after normalization' {
        { InModuleScope AdLifecycle { ConvertTo-AdSamAccountName -GivenName '李' -Surname '王' } } |
            Should -Throw '*no letters a-z or digits remain*'
    }
}

Describe 'Resolve-AdSamAccountName' {
    It 'returns the base name when it is free, checking both sAMAccountName and UPN' {
        $actual = InModuleScope AdLifecycle {
            Resolve-AdSamAccountName -GivenName 'Lucía' -Surname 'Muñoz' -UpnSuffix 'corp.example'
        }
        $actual | Should -BeExactly 'lmunoz'
        Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter {
            $LDAPFilter -eq '(|(sAMAccountName=lmunoz)(userPrincipalName=lmunoz@corp.example))'
        }
    }

    It 'appends 2, 3, ... while the name is taken' {
        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter {
            $LDAPFilter -like '*(sAMAccountName=lmunoz)*' -or $LDAPFilter -like '*(sAMAccountName=lmunoz2)*'
        } -MockWith { [pscustomobject]@{ SamAccountName = 'taken' } }

        $actual = InModuleScope AdLifecycle {
            Resolve-AdSamAccountName -GivenName 'Lucía' -Surname 'Muñoz' -UpnSuffix 'corp.example'
        }
        $actual | Should -BeExactly 'lmunoz3'
        Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 3 -Exactly
    }

    It 'keeps collision suffixes within 20 characters' {
        Mock Get-ADUser -ModuleName AdLifecycle -ParameterFilter {
            $LDAPFilter -like '*(sAMAccountName=mfernandezcastellano)*'
        } -MockWith { [pscustomobject]@{ SamAccountName = 'taken' } }

        $actual = InModuleScope AdLifecycle {
            Resolve-AdSamAccountName -GivenName 'Maximiliano' -Surname 'Fernández-Castellanos' -UpnSuffix 'corp.example'
        }
        $actual | Should -BeExactly 'mfernandezcastellan2'
    }

    It 'skips names reserved earlier in the same run without asking AD' {
        $actual = InModuleScope AdLifecycle {
            Resolve-AdSamAccountName -GivenName 'Lucía' -Surname 'Muñoz' -UpnSuffix 'corp.example' -Reserved 'lmunoz'
        }
        $actual | Should -BeExactly 'lmunoz2'
        Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 0 -Exactly -ParameterFilter {
            $LDAPFilter -like '*(sAMAccountName=lmunoz)*'
        }
    }

    It 'gives up with a clear error after MaxSuffix attempts' {
        Mock Get-ADUser -ModuleName AdLifecycle -MockWith { [pscustomobject]@{ SamAccountName = 'taken' } }
        { InModuleScope AdLifecycle { Resolve-AdSamAccountName -GivenName 'Ana' -Surname 'Gomez' -UpnSuffix 'corp.example' -MaxSuffix 5 } } |
            Should -Throw '*No free sAMAccountName*'
        Should -Invoke Get-ADUser -ModuleName AdLifecycle -Times 5 -Exactly
    }
}
