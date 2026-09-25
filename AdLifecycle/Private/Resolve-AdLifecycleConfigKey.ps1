function Resolve-AdLifecycleConfigKey {
    <#
    .SYNOPSIS
        Returns the configured spelling of a site or department name, or nothing if unknown.

    .DESCRIPTION
        Matches case-insensitively and ignores surrounding spaces, so 'finance ' resolves to
        'Finance' and the value written to AD is always the one from the configuration file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Table,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    $wanted = $Name.Trim()
    foreach ($key in $Table.Keys) {
        if ([string]$key -eq $wanted) {
            return [string]$key
        }
    }
}
