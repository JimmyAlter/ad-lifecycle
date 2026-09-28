function Get-AdLifecycleConnection {
    <#
    .SYNOPSIS
        Builds the -Server / -Credential splat that every AD call of one command run uses.

    .DESCRIPTION
        Returns a hashtable with Server and/or Credential, to be splatted into every AD cmdlet
        call of a command, so all reads and writes of one run go to the same domain controller.

        - -Server given: used as is.
        - -Server not given and -DiscoverWritable: one writable domain controller is located once
          with Get-ADDomainController -Discover -Writable and pinned for the whole run. This is
          what keeps a joiner's group adds on the DC that just created the account, instead of a
          DC that has not replicated it yet.
        - -Server not given, no -DiscoverWritable (read-only commands): no Server key; the AD
          module picks a DC as usual.

        Credential is added only when it is not [PSCredential]::Empty.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,

        [switch]$DiscoverWritable
    )

    $connection = @{}

    if (-not [string]::IsNullOrWhiteSpace($Server)) {
        $connection['Server'] = $Server.Trim()
    } elseif ($DiscoverWritable) {
        try {
            $domainController = Get-ADDomainController -Discover -Writable -ErrorAction Stop
        } catch {
            throw ('Could not locate a writable domain controller; pass -Server: {0}' -f $_.Exception.Message)
        }
        $hostName = @($domainController | ForEach-Object { $_.HostName } | Where-Object { $_ }) | Select-Object -First 1
        if (-not $hostName) {
            throw 'Could not locate a writable domain controller; pass -Server.'
        }
        $connection['Server'] = [string]$hostName
        Write-Verbose ("Using writable domain controller '{0}' for every call in this run." -f $connection['Server'])
    }

    if ($null -ne $Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $connection['Credential'] = $Credential
    }

    $connection
}
