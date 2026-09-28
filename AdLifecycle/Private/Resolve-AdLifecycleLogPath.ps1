function Resolve-AdLifecycleLogPath {
    <#
    .SYNOPSIS
        Works out the audit log file for a run: -LogPath, else LogPath from the configuration.

    .DESCRIPTION
        Returns the full file system path, or nothing when no audit log is configured. Relative
        paths are resolved against the current PowerShell location. Throws when the folder does
        not exist, so a run never starts writing to AD without being able to log it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$LogPath,

        [System.Collections.IDictionary]$Config = @{}
    )

    $path = $LogPath
    if ([string]::IsNullOrWhiteSpace($path) -and $Config.Contains('LogPath')) {
        $path = [string]$Config['LogPath']
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    $folder = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw ("The folder of the audit log '{0}' does not exist." -f $fullPath)
    }
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        throw ("The audit log path '{0}' is a folder; give a file name." -f $fullPath)
    }
    $fullPath
}
