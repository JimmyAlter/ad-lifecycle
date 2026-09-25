BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'New-AdInitialPassword' {
    It 'returns a read-only SecureString, never a plain string' {
        $password = InModuleScope AdLifecycle { New-AdInitialPassword }
        $password | Should -BeOfType [securestring]
        @($password).Count | Should -Be 1
        $password.IsReadOnly() | Should -BeTrue
    }

    It 'is 16 characters long by default' {
        (InModuleScope AdLifecycle { New-AdInitialPassword }).Length | Should -Be 16
    }

    It 'honours -Length <Length>' -ForEach @(@{ Length = 12 }, @{ Length = 24 }, @{ Length = 128 }) {
        $password = InModuleScope AdLifecycle -Parameters @{ L = $Length } { param($L) New-AdInitialPassword -Length $L }
        $password.Length | Should -Be $Length
        (ConvertFrom-TestSecureString $password).Length | Should -Be $Length
    }

    It 'rejects lengths below 12 or above 128' {
        { InModuleScope AdLifecycle { New-AdInitialPassword -Length 11 } } | Should -Throw
        { InModuleScope AdLifecycle { New-AdInitialPassword -Length 129 } } | Should -Throw
    }

    It 'always contains an uppercase letter, a lowercase letter, a digit and a symbol (500 samples)' {
        $plain = InModuleScope AdLifecycle {
            1..500 | ForEach-Object { [System.Net.NetworkCredential]::new('', (New-AdInitialPassword -Length 12)).Password }
        }
        foreach ($p in $plain) {
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -Match '[0-9]'
            $p | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'only uses unambiguous characters from the allowed set' {
        $plain = InModuleScope AdLifecycle {
            1..200 | ForEach-Object { [System.Net.NetworkCredential]::new('', (New-AdInitialPassword -Length 32)).Password }
        }
        foreach ($p in $plain) {
            $p | Should -MatchExactly '^[A-HJ-NP-Za-km-z2-9!#%*+=?@_-]+$'
        }
    }

    It 'does not repeat itself (200 passwords, all distinct)' {
        $plain = InModuleScope AdLifecycle {
            1..200 | ForEach-Object { [System.Net.NetworkCredential]::new('', (New-AdInitialPassword)).Password }
        }
        @($plain | Sort-Object -Unique -CaseSensitive).Count | Should -Be 200
    }

    It 'spreads characters over the whole alphabet (no position is constant)' {
        $plain = InModuleScope AdLifecycle {
            1..200 | ForEach-Object { [System.Net.NetworkCredential]::new('', (New-AdInitialPassword)).Password }
        }
        # The four guaranteed classes are shuffled in, so no position may be stuck on one class.
        foreach ($position in 0..3) {
            $classes = $plain | ForEach-Object {
                $c = [string]$_[$position]
                if ($c -cmatch '[A-Z]') { 'upper' } elseif ($c -cmatch '[a-z]') { 'lower' } elseif ($c -match '[0-9]') { 'digit' } else { 'symbol' }
            }
            @($classes | Sort-Object -Unique).Count | Should -BeGreaterThan 1
        }
    }
}
