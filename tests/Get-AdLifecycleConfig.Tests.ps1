BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Get-AdLifecycleConfig' {
    It 'loads the example configuration' {
        $config = InModuleScope AdLifecycle -Parameters @{ P = $ExampleConfigPath } { param($P) Get-AdLifecycleConfig -Path $P }
        $config | Should -BeOfType [hashtable]
        $config.UpnSuffix | Should -Be 'corp.example'
        $config.Sites.Keys | Should -Contain 'Madrid'
        $config.Departments['Finance'] | Should -Contain 'GG-Finance'
    }

    It 'throws when the file does not exist' {
        $missing = Join-Path $TestDrive 'nope.psd1'
        { InModuleScope AdLifecycle -Parameters @{ P = $missing } { param($P) Get-AdLifecycleConfig -Path $P } } |
            Should -Throw '*was not found*'
    }

    It 'throws when the file is not a data file (and never executes it)' {
        $path = Join-Path $TestDrive 'code.psd1'
        $marker = Join-Path $TestDrive 'pwned.txt'
        Set-Content -Path $path -Value "@{ UpnSuffix = (New-Item -Path '$marker') }"
        { InModuleScope AdLifecycle -Parameters @{ P = $path } { param($P) Get-AdLifecycleConfig -Path $P } } |
            Should -Throw '*Could not read*'
        $marker | Should -Not -Exist
    }

    It 'throws and lists every problem when the configuration is invalid' {
        $path = Join-Path $TestDrive 'broken.psd1'
        Set-Content -Path $path -Value @'
@{
    UpnSuffix   = 'corp.example'
    DisabledOU  = 'Disabled Users'
    Sites       = @{ Madrid = '' }
    Departments = @{ Finance = @('GG-Finance') }
}
'@
        $thrown = $null
        try {
            InModuleScope AdLifecycle -Parameters @{ P = $path } { param($P) Get-AdLifecycleConfig -Path $P }
        } catch {
            $thrown = $_.Exception.Message
        }
        $thrown | Should -BeLike '*is invalid*'
        $thrown | Should -BeLike '*DisabledOU:*'
        $thrown | Should -BeLike '*Sites.Madrid:*'
    }
}

Describe 'Resolve-AdLifecycleConfigKey' {
    It 'returns the configured spelling for a case-insensitive, space-tolerant match' {
        InModuleScope AdLifecycle { Resolve-AdLifecycleConfigKey -Table @{ 'Buenos Aires' = 1; 'Finance' = 2 } -Name ' finance ' } |
            Should -BeExactly 'Finance'
        InModuleScope AdLifecycle { Resolve-AdLifecycleConfigKey -Table @{ 'Buenos Aires' = 1; 'Finance' = 2 } -Name 'BUENOS AIRES' } |
            Should -BeExactly 'Buenos Aires'
    }

    It 'returns nothing for an unknown name' {
        InModuleScope AdLifecycle { Resolve-AdLifecycleConfigKey -Table @{ 'Finance' = 2 } -Name 'Fin' } | Should -BeNullOrEmpty
    }
}

Describe 'Assert-AdModule' {
    It 'passes when the AD cmdlets are available' {
        { InModuleScope AdLifecycle { Assert-AdModule } } | Should -Not -Throw
    }

    It 'throws a clear NotInstalled error when the ActiveDirectory module is missing' {
        Mock Get-Command -ModuleName AdLifecycle -ParameterFilter { $Name -eq 'Get-ADUser' } -MockWith { }
        Mock Get-Module -ModuleName AdLifecycle -ParameterFilter { $Name -eq 'ActiveDirectory' } -MockWith { }

        $record = $null
        try {
            InModuleScope AdLifecycle { Assert-AdModule }
        } catch {
            $record = $_
        }
        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'ActiveDirectoryModuleMissing*'
        $record.CategoryInfo.Category | Should -Be 'NotInstalled'
        $record.Exception.Message | Should -BeLike '*RSAT*'
    }
}
