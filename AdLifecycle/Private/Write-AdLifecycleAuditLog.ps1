function Write-AdLifecycleAuditLog {
    <#
    .SYNOPSIS
        Appends one JSON line describing a change to the audit log (JSON Lines, UTF-8, no BOM).

    .DESCRIPTION
        One line per user per command run that attempted a change:

            TimestampUtc, Operator, CredentialUser, Server, Command, Target, DistinguishedName,
            Ticket, Changes, Applied, FailedGroups, Errors

        Changes is what was planned (groups, OU, attributes). Callers never pass passwords;
        the joiner's initial password is not part of Changes.

        Writing the log must never undo or hide an AD change that already happened (the joiner
        still has to return the initial password), so a failure to write is a warning, not an
        error. Nothing is logged under -WhatIf: the callers only log after ShouldProcess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$Target,

        [string]$DistinguishedName,

        [string]$Ticket,

        [System.Collections.IDictionary]$Changes = @{},

        [bool]$Applied,

        [string[]]$FailedGroups = @(),

        [string[]]$Errors = @(),

        [hashtable]$Connection = @{}
    )

    $credentialUser = $null
    if ($Connection.ContainsKey('Credential')) {
        $credentialUser = [string]$Connection['Credential'].UserName
    }

    $entry = [ordered]@{
        TimestampUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        Operator          = Get-AdLifecycleOperator
        CredentialUser    = $credentialUser
        Server            = $Connection['Server']
        Command           = $Command
        Target            = $Target
        DistinguishedName = $DistinguishedName
        Ticket            = $Ticket
        Changes           = $Changes
        Applied           = $Applied
        FailedGroups      = @($FailedGroups | Where-Object { $_ })
        Errors            = @($Errors | Where-Object { $_ })
    }
    # Unbound [string] parameters are '' - log them as null.
    foreach ($key in 'DistinguishedName', 'Ticket') {
        if (-not $entry[$key]) {
            $entry[$key] = $null
        }
    }

    try {
        $line = ConvertTo-Json -InputObject $entry -Compress -Depth 5
        [System.IO.File]::AppendAllText($Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Warning ("Could not write the audit log entry for '{0}' to '{1}': {2}" -f $Target, $Path, $_.Exception.Message)
    }
}
