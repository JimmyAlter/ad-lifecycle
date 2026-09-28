BeforeDiscovery {
    $moduleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdLifecycle'
    $publicFunctions = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue |
            ForEach-Object { @{ Name = $_.BaseName } })
    $mutatingFunctions = @(@(
        @{ Name = 'New-AdLifecycleUser' }
        @{ Name = 'Set-AdLifecycleDepartment' }
        @{ Name = 'Disable-AdLifecycleUser' }
    ) | Where-Object { Test-Path (Join-Path (Join-Path $moduleRoot 'Public') "$($_.Name).ps1") })
    $readOnlyFunctions = @(@(
        @{ Name = 'Get-AdStaleComputer' }
        @{ Name = 'Test-AdLifecycleConfig' }
    ) | Where-Object { Test-Path (Join-Path (Join-Path $moduleRoot 'Public') "$($_.Name).ps1") })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $ManifestPath -Force
    $manifest = Import-PowerShellDataFile -Path $ManifestPath

    $publicNames = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName } | Sort-Object)
    $privateNames = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName } | Sort-Object)

    function Get-CommandNameInFile {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ }
    }
}

AfterAll {
    Remove-Module -Name AdLifecycle -Force -ErrorAction SilentlyContinue
}

Describe 'AdLifecycle manifest' {
    It 'is a valid module manifest' {
        { Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'targets Windows PowerShell 5.1 and PowerShell 7' {
        $manifest.PowerShellVersion | Should -Be '5.1'
        $manifest.CompatiblePSEditions | Should -Be @('Desktop', 'Core')
    }

    It 'does not declare RequiredModules (ActiveDirectory is checked at call time)' {
        $manifest.ContainsKey('RequiredModules') | Should -BeFalse
        (Get-Module AdLifecycle).RequiredModules | Should -BeNullOrEmpty
    }

    It 'has gallery metadata (project, license, release notes, edition tags)' {
        $psData = $manifest.PrivateData.PSData
        $psData.ProjectUri | Should -Be 'https://github.com/JimmyAlter/ad-lifecycle'
        $psData.LicenseUri | Should -Be 'https://github.com/JimmyAlter/ad-lifecycle/blob/main/LICENSE'
        $psData.ReleaseNotes | Should -Not -BeNullOrEmpty
        foreach ($tag in 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'ActiveDirectory') {
            $psData.Tags | Should -Contain $tag
        }
    }

    It 'lists FunctionsToExport explicitly (no wildcards)' {
        $manifest.FunctionsToExport | Should -Not -Contain '*'
        @($manifest.FunctionsToExport | Sort-Object) | Should -Be $publicNames
    }
}

Describe 'AdLifecycle exports' {
    It 'exports exactly the functions in Public/' {
        @((Get-Module AdLifecycle).ExportedFunctions.Keys | Sort-Object) | Should -Be $publicNames
    }

    It 'does not export any private helper' {
        $exported = @((Get-Module AdLifecycle).ExportedFunctions.Keys)
        foreach ($name in $privateNames) {
            $exported | Should -Not -Contain $name
        }
    }

    It 'exports no cmdlets, aliases or variables' {
        (Get-Module AdLifecycle).ExportedCmdlets.Count | Should -Be 0
        (Get-Module AdLifecycle).ExportedAliases.Count | Should -Be 0
        (Get-Module AdLifecycle).ExportedVariables.Count | Should -Be 0
    }

    It 'imports in a fresh session that has no ActiveDirectory module loaded' {
        $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$ManifestPath'
[pscustomobject]@{
    Exported = @((Get-Module AdLifecycle).ExportedFunctions.Keys).Count
    AdLoaded = [bool](Get-Module -Name ActiveDirectory)
} | ConvertTo-Json -Compress
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
        $arguments = @('-NoProfile', '-NonInteractive')
        if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
            $arguments += @('-ExecutionPolicy', 'Bypass')
        }
        $output = & (Get-Process -Id $PID).Path @arguments -EncodedCommand $encoded
        $LASTEXITCODE | Should -Be 0
        $state = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $state.Exported | Should -Be $publicNames.Count
        $state.AdLoaded | Should -BeFalse
    }
}

Describe 'Comment-based help for <Name>' -ForEach $publicFunctions {
    BeforeAll {
        $help = Get-Help -Name $Name -Full
        $command = Get-Command -Name $Name
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    }

    It 'has a synopsis' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeLike "$Name *"
    }

    It 'has a description' {
        ($help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        foreach ($parameter in $command.Parameters.Keys | Where-Object { $common -notcontains $_ }) {
            $entry = @($help.Parameters.Parameter) | Where-Object { $_.Name -eq $parameter }
            ($entry.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "-$parameter should be documented"
        }
    }
}

Describe 'Write safety' {
    It '<Name> supports -WhatIf/-Confirm with ConfirmImpact High' -ForEach $mutatingFunctions {
        $binding = (Get-Command -Name $Name).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $binding.SupportsShouldProcess | Should -BeTrue
        $binding.ConfirmImpact | Should -Be 'High'
    }

    It '<Name> is read-only: it calls no AD write cmdlet' -ForEach $readOnlyFunctions {
        $path = Join-Path (Join-Path $ModuleRoot 'Public') "$Name.ps1"
        $adCalls = @(Get-CommandNameInFile -Path $path | Where-Object { $_ -cmatch '^[A-Z][a-z]+-AD[A-Z]' })
        $adCalls | Where-Object { $_ -notlike 'Get-*' } | Should -BeNullOrEmpty
    }

    It 'every AD cmdlet the module calls is stubbed and mocked by the test suite' {
        $files = Get-ChildItem -Path $ModuleRoot -Recurse -Include '*.ps1', '*.psm1'
        $adCalls = @($files | ForEach-Object { Get-CommandNameInFile -Path $_.FullName } |
                Where-Object { $_ -cmatch '^[A-Z][a-z]+-AD[A-Z]' } | Sort-Object -Unique)
        $adCalls | Where-Object { $AdCommandNames -notcontains $_ } | Should -BeNullOrEmpty
    }
}

Describe 'Source encoding' {
    # Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI, which silently corrupts
    # literals such as "Mu<n-tilde>oz". These tests keep that from coming back.
    BeforeAll {
        function Test-NonAscii {
            param([byte[]]$Bytes)
            foreach ($byte in $Bytes) {
                if ($byte -gt 0x7F) { return $true }
            }
            $false
        }
        function Test-Utf8Bom {
            param([byte[]]$Bytes)
            $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
        }
    }

    It 'every PowerShell or CSV file with non-ASCII characters is UTF-8 with BOM' {
        $files = Get-ChildItem -Path $RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.csv' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|testResults)[\\/]' }
        $offenders = foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if ((Test-NonAscii $bytes) -and -not (Test-Utf8Bom $bytes)) { $file.FullName }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'module source is ASCII-only (non-ASCII characters are written as code points)' {
        $offenders = foreach ($file in Get-ChildItem -Path $ModuleRoot -Recurse -File) {
            if (Test-NonAscii ([System.IO.File]::ReadAllBytes($file.FullName))) { $file.FullName }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'this test run decodes non-ASCII literals correctly' {
        'Muñoz'.Length | Should -Be 5
        'Muñoz'[2] | Should -Be ([char]0x00F1)
    }
}
