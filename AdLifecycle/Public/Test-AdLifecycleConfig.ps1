function Test-AdLifecycleConfig {
    <#
    .SYNOPSIS
        Validates an AdLifecycle configuration file and returns the problems found.

    .DESCRIPTION
        Loads the .psd1 file with Import-PowerShellDataFile (data only, no code is executed) and
        checks that:

        - UpnSuffix is present and is a valid DNS suffix
        - DisabledOU is present, is a valid OU distinguished name, and is not also a site OU
        - Sites has at least one site, every site has an OU, and every OU is a valid DN
        - Departments has at least one department and every department has a list of groups
        - CommonGroups, if present, is a list of group names
        - PasswordLength, if present, is a whole number between 12 and 128
        - there are no unknown settings (catches typos such as "DisableOU" or "Department")

        Returns one AdLifecycle.ConfigProblem object (Path, Setting, Message) per problem and
        nothing when the configuration is valid. With -Strict it throws instead, which is handy
        at the top of a script or in CI.

        Read-only and offline: it never contacts Active Directory, so it does not check that the
        OUs or groups exist. The commands that change AD run the same checks and refuse to start
        on an invalid configuration.

    .PARAMETER Path
        Path to the .psd1 configuration file. Accepts pipeline input (strings or Get-ChildItem).

    .PARAMETER Config
        A configuration hashtable to validate instead of a file.

    .PARAMETER Strict
        Throw a terminating error listing every problem instead of returning them.

    .EXAMPLE
        Test-AdLifecycleConfig -Path .\lifecycle.config.psd1

        Returns nothing when the file is valid, otherwise one object per problem.

    .EXAMPLE
        Test-AdLifecycleConfig -Path .\lifecycle.config.psd1 -Strict

        Throws when the file is invalid. Use it as a guard at the top of a script.

    .EXAMPLE
        Get-ChildItem .\config\*.psd1 | Test-AdLifecycleConfig | Format-Table Path, Setting, Message

        Validates the configuration of several domains at once.

    .OUTPUTS
        AdLifecycle.ConfigProblem
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType('AdLifecycle.ConfigProblem')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Config')]
        [hashtable]$Config,

        [switch]$Strict
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Config') {
            $source = '(in memory)'
            $problems = @(Get-AdLifecycleConfigProblem -Config $Config -Path $source)
        } elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $source = $Path
            $problems = @([pscustomobject]@{
                    PSTypeName = 'AdLifecycle.ConfigProblem'
                    Path       = $source
                    Setting    = '(file)'
                    Message    = 'File not found.'
                })
        } else {
            $source = (Resolve-Path -LiteralPath $Path).ProviderPath
            try {
                $data = Import-PowerShellDataFile -LiteralPath $source -ErrorAction Stop
                $problems = @(Get-AdLifecycleConfigProblem -Config $data -Path $source)
            } catch {
                $problems = @([pscustomobject]@{
                        PSTypeName = 'AdLifecycle.ConfigProblem'
                        Path       = $source
                        Setting    = '(file)'
                        Message    = 'Not a valid PowerShell data file: {0}' -f $_.Exception.Message
                    })
            }
        }

        if ($Strict -and $problems.Count -gt 0) {
            $lines = @($problems | ForEach-Object { '  - {0}: {1}' -f $_.Setting, $_.Message })
            $details = $lines -join [Environment]::NewLine
            throw ("AdLifecycle configuration '{0}' is invalid:{1}{2}" -f $source, [Environment]::NewLine, $details)
        }

        $problems
    }
}
