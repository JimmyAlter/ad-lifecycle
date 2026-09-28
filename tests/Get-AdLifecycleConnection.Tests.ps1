BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    Register-AdDefaultMock
}

Describe 'Get-AdLifecycleConnection' {
    BeforeAll {
        $credential = [pscredential]::new('CORP\svc-lifecycle', [securestring]::new())
    }

    It 'uses -Server as given and does not discover a DC' {
        $connection = InModuleScope AdLifecycle { Get-AdLifecycleConnection -Server ' dc07.corp.example ' -DiscoverWritable }

        $connection.Server | Should -Be 'dc07.corp.example'
        $connection.ContainsKey('Credential') | Should -BeFalse
        Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 0 -Exactly
    }

    It 'discovers one writable DC when -Server is not given' {
        $connection = InModuleScope AdLifecycle { Get-AdLifecycleConnection -DiscoverWritable }

        $connection.Server | Should -Be $TestDomainController
        Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 1 -Exactly -ParameterFilter { $Discover -and $Writable }
    }

    It 'returns an empty splat for read-only use without -Server' {
        $connection = InModuleScope AdLifecycle { Get-AdLifecycleConnection }

        $connection.Count | Should -Be 0
        Should -Invoke Get-ADDomainController -ModuleName AdLifecycle -Times 0 -Exactly
    }

    It 'adds the credential when one is given' {
        $connection = InModuleScope AdLifecycle -Parameters @{ C = $credential } { param($C) Get-AdLifecycleConnection -Server dc07 -Credential $C }

        $connection.Credential.UserName | Should -Be 'CORP\svc-lifecycle'
    }

    It 'throws a clear error when no writable DC can be located' {
        Mock Get-ADDomainController -ModuleName AdLifecycle -MockWith { throw 'The specified domain either does not exist or could not be contacted' }

        { InModuleScope AdLifecycle { Get-AdLifecycleConnection -DiscoverWritable } } |
            Should -Throw '*Could not locate a writable domain controller; pass -Server*could not be contacted*'
    }

    It 'throws when discovery returns no host name' {
        Mock Get-ADDomainController -ModuleName AdLifecycle -MockWith { [pscustomobject]@{ HostName = @() } }

        { InModuleScope AdLifecycle { Get-AdLifecycleConnection -DiscoverWritable } } |
            Should -Throw '*Could not locate a writable domain controller*'
    }
}
