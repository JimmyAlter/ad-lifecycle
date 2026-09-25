function Get-AdLifecycleConfig {
    <#
    .SYNOPSIS
        Loads and validates an AdLifecycle configuration file.

    .DESCRIPTION
        Reads the .psd1 file with Import-PowerShellDataFile (data only: no code in the file is
        executed), validates it with Get-AdLifecycleConfigProblem and throws if anything is wrong,
        listing every problem. Commands that change AD call this before doing anything, so a
        broken configuration can never lead to a half-applied change.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("AdLifecycle configuration file '{0}' was not found." -f $Path)
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath

    try {
        $config = Import-PowerShellDataFile -LiteralPath $resolvedPath -ErrorAction Stop
    } catch {
        throw ("Could not read AdLifecycle configuration '{0}': {1}" -f $resolvedPath, $_.Exception.Message)
    }

    $problems = @(Get-AdLifecycleConfigProblem -Config $config -Path $resolvedPath)
    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { '  - {0}: {1}' -f $_.Setting, $_.Message })
        $details = $lines -join [Environment]::NewLine
        throw ("AdLifecycle configuration '{0}' is invalid:{1}{2}" -f $resolvedPath, [Environment]::NewLine, $details)
    }

    $config
}
