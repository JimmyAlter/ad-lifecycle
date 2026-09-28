@{
    RootModule           = 'AdLifecycle.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '4917c232-263e-4053-b2cb-cd3e90979489'
    Author               = 'Thiago Langone'
    Copyright            = '(c) 2026 Thiago Langone. MIT License.'
    Description          = 'Joiner / mover / leaver and hygiene tooling for on-premises Active Directory. Read-only by default; every write supports -WhatIf and -Confirm.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # The ActiveDirectory module (RSAT) is deliberately NOT listed in RequiredModules:
    # that would make the module impossible to import (and test) on machines without RSAT.
    # Commands that talk to AD check for it at call time instead.

    FunctionsToExport    = @(
        'New-AdLifecycleUser'
        'Set-AdLifecycleUser'
        'Disable-AdLifecycleUser'
        'Get-AdStaleComputer'
        'Test-AdLifecycleConfig'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Set-AdLifecycleDepartment')

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'ActiveDirectory', 'AD', 'Provisioning', 'JoinerMoverLeaver', 'Identity', 'Windows',
                'PSEdition_Desktop', 'PSEdition_Core'
            )
            ProjectUri   = 'https://github.com/JimmyAlter/ad-lifecycle'
            LicenseUri   = 'https://github.com/JimmyAlter/ad-lifecycle/blob/main/LICENSE'
            ReleaseNotes = 'See https://github.com/JimmyAlter/ad-lifecycle/blob/main/CHANGELOG.md'
        }
    }
}
