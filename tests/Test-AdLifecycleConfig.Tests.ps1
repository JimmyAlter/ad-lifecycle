BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock

    # A fresh, valid copy of the example configuration for each test to break.
    function Get-ValidConfig { Import-PowerShellDataFile -Path $ExampleConfigPath }
}

Describe 'Test-AdLifecycleConfig' {
    Context 'valid configuration' {
        It 'returns nothing for the example configuration file' {
            Test-AdLifecycleConfig -Path $ExampleConfigPath | Should -BeNullOrEmpty
        }

        It 'does not throw with -Strict for a valid file' {
            { Test-AdLifecycleConfig -Path $ExampleConfigPath -Strict } | Should -Not -Throw
        }

        It 'accepts a minimal configuration without the optional settings' {
            $config = @{
                UpnSuffix   = 'corp.example'
                DisabledOU  = 'OU=Disabled,DC=corp,DC=example'
                Sites       = @{ HQ = 'CN=Users,DC=corp,DC=example' }
                Departments = @{ IT = 'GG-IT' }
            }
            Test-AdLifecycleConfig -Config $config | Should -BeNullOrEmpty
        }

        It 'accepts escaped commas in OU names' {
            $config = Get-ValidConfig
            $config.Sites['Madrid'] = 'OU=Madrid\, Centro,OU=Sites,OU=Corp,DC=corp,DC=example'
            Test-AdLifecycleConfig -Config $config | Should -BeNullOrEmpty
        }
    }

    Context 'broken configuration' {
        It 'reports <Case>' -ForEach @(
            @{ Case = 'a missing UpnSuffix'; Setting = 'UpnSuffix'; Break = { param($c) $c.Remove('UpnSuffix') } }
            @{ Case = 'an invalid UpnSuffix'; Setting = 'UpnSuffix'; Break = { param($c) $c.UpnSuffix = 'corp example' } }
            @{ Case = 'a missing DisabledOU'; Setting = 'DisabledOU'; Break = { param($c) $c.Remove('DisabledOU') } }
            @{ Case = 'a DisabledOU that is not a DN'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = 'Disabled Users' } }
            @{ Case = 'a DisabledOU with the wrong separator'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = 'OU=Disabled;DC=corp,DC=example' } }
            @{ Case = 'a DisabledOU without DC components'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = 'OU=Disabled,OU=Corp' } }
            @{ Case = 'a DisabledOU that is the domain root'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = 'DC=corp,DC=example' } }
            @{ Case = 'a DisabledOU with an empty component'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = 'OU=,DC=corp,DC=example' } }
            @{ Case = 'a DisabledOU that is also a site OU'; Setting = 'DisabledOU'; Break = { param($c) $c.DisabledOU = $c.Sites['Madrid'] } }
            @{ Case = 'missing Sites'; Setting = 'Sites'; Break = { param($c) $c.Remove('Sites') } }
            @{ Case = 'empty Sites'; Setting = 'Sites'; Break = { param($c) $c.Sites = @{} } }
            @{ Case = 'Sites that is not a hashtable'; Setting = 'Sites'; Break = { param($c) $c.Sites = @('Madrid') } }
            @{ Case = 'a site without an OU'; Setting = 'Sites.Madrid'; Break = { param($c) $c.Sites['Madrid'] = '' } }
            @{ Case = 'a site with an invalid OU'; Setting = 'Sites.Madrid'; Break = { param($c) $c.Sites['Madrid'] = 'Madrid Users' } }
            @{ Case = 'missing Departments'; Setting = 'Departments'; Break = { param($c) $c.Remove('Departments') } }
            @{ Case = 'empty Departments'; Setting = 'Departments'; Break = { param($c) $c.Departments = @{} } }
            @{ Case = 'a department without groups'; Setting = 'Departments.Finance'; Break = { param($c) $c.Departments['Finance'] = @() } }
            @{ Case = 'a department with a null group list'; Setting = 'Departments.Finance'; Break = { param($c) $c.Departments['Finance'] = $null } }
            @{ Case = 'a department with a blank group name'; Setting = 'Departments.Finance'; Break = { param($c) $c.Departments['Finance'] = @('GG-Finance', ' ') } }
            @{ Case = 'CommonGroups that is not a list of names'; Setting = 'CommonGroups'; Break = { param($c) $c.CommonGroups = @{ All = 'GG-All-Staff' } } }
            @{ Case = 'a PasswordLength below 12'; Setting = 'PasswordLength'; Break = { param($c) $c.PasswordLength = 8 } }
            @{ Case = 'a PasswordLength above 128'; Setting = 'PasswordLength'; Break = { param($c) $c.PasswordLength = 256 } }
            @{ Case = 'a PasswordLength that is not a number'; Setting = 'PasswordLength'; Break = { param($c) $c.PasswordLength = 'sixteen' } }
            @{ Case = 'an empty LogPath'; Setting = 'LogPath'; Break = { param($c) $c.LogPath = '' } }
            @{ Case = 'a LogPath that is not a string'; Setting = 'LogPath'; Break = { param($c) $c.LogPath = @('a', 'b') } }
            @{ Case = 'an unknown setting (typo)'; Setting = 'DisableOU'; Break = { param($c) $c.DisableOU = 'OU=Disabled,DC=corp,DC=example' } }
        ) {
            $config = Get-ValidConfig
            & $Break $config

            $problems = @(Test-AdLifecycleConfig -Config $config)

            $problems.Count | Should -BeGreaterThan 0
            $problems.Setting | Should -Contain $Setting
            ($problems | Where-Object Setting -EQ $Setting).Message | Should -Not -BeNullOrEmpty
        }

        It 'reports every problem at once, as typed objects' {
            $config = Get-ValidConfig
            $config.Remove('DisabledOU')
            $config.Sites['Madrid'] = ''
            $config.Departments['Finance'] = @()

            $problems = @(Test-AdLifecycleConfig -Config $config)

            $problems.Count | Should -Be 3
            $problems | ForEach-Object { $_.PSObject.TypeNames | Should -Contain 'AdLifecycle.ConfigProblem' }
            $problems[0].PSObject.Properties.Name | Should -Be @('Path', 'Setting', 'Message')
        }

        It 'throws with -Strict and lists each problem' {
            $config = Get-ValidConfig
            $config.Remove('DisabledOU')
            $config.Sites['Madrid'] = ''

            { Test-AdLifecycleConfig -Config $config -Strict } | Should -Throw '*DisabledOU:*Sites.Madrid:*'
        }
    }

    Context 'files' {
        It 'reports a missing file' {
            $path = Join-Path $TestDrive 'missing.psd1'
            $problem = Test-AdLifecycleConfig -Path $path

            $problem.Setting | Should -Be '(file)'
            $problem.Message | Should -Be 'File not found.'
            $problem.Path | Should -Be $path
        }

        It 'reports a file that is not valid PowerShell data' {
            $path = Join-Path $TestDrive 'syntax.psd1'
            Set-Content -Path $path -Value "@{ UpnSuffix = 'corp.example'"

            (Test-AdLifecycleConfig -Path $path).Setting | Should -Be '(file)'
        }

        It 'refuses files that contain code instead of data, without running it' {
            $path = Join-Path $TestDrive 'code.psd1'
            $marker = Join-Path $TestDrive 'ran.txt'
            Set-Content -Path $path -Value "@{ UpnSuffix = (New-Item -Path '$marker') }"

            (Test-AdLifecycleConfig -Path $path).Message | Should -BeLike 'Not a valid PowerShell data file*'
            $marker | Should -Not -Exist
        }

        It 'reads a broken file and reports its path' {
            $path = Join-Path $TestDrive 'broken.psd1'
            (Get-Content -Path $ExampleConfigPath -Raw) -replace "UpnSuffix      = 'corp.example'", "UpnSuffix = ''" |
                Set-Content -Path $path

            $problem = Test-AdLifecycleConfig -Path $path

            $problem.Setting | Should -Be 'UpnSuffix'
            $problem.Path | Should -Be (Resolve-Path -LiteralPath $path).ProviderPath
        }

        It 'accepts files from the pipeline' {
            $good = Join-Path $TestDrive 'good.psd1'
            Copy-Item -Path $ExampleConfigPath -Destination $good
            $missing = Join-Path $TestDrive 'nope.psd1'

            $problems = @(Get-Item -Path $good | Test-AdLifecycleConfig) + @($missing | Test-AdLifecycleConfig)

            $problems.Count | Should -Be 1
            $problems[0].Path | Should -Be $missing
        }
    }
}
