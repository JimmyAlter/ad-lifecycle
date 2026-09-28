# Shared setup, dot-sourced from BeforeAll in every test file:
#
#     BeforeAll {
#         . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
#         Import-Module $ManifestPath -Force
#         Register-AdDefaultMock
#     }
#
# How Active Directory is faked:
# 1. Stubs. If a cmdlet of the ActiveDirectory module is not installed (CI, Linux, no RSAT), a
#    global stub function with the same name and parameter names is defined, so Pester has
#    something to mock. A stub that is ever called without a mock throws.
# 2. Default mocks. Register-AdDefaultMock mocks EVERY AD cmdlet the module can call, inside the
#    module's scope: reads return nothing, writes do nothing. Tests override them as needed.
#    The one exception is Get-ADDomainController, which returns the fictional writable DC
#    $TestDomainController, so the commands that write can pin it.
#    On a machine that does have RSAT this means no test can reach a real directory, and
#    Module.Tests.ps1 fails if the module ever calls an AD cmdlet that is not in this list.

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModuleRoot = Join-Path $RepoRoot 'AdLifecycle'
$ManifestPath = Join-Path $ModuleRoot 'AdLifecycle.psd1'
$ExampleConfigPath = Join-Path (Join-Path $RepoRoot 'examples') 'lifecycle.config.psd1'

$AdStubDefinitions = [ordered]@{
    'Get-ADUser'                     = {
        [CmdletBinding()]
        param($Identity, $Filter, $LDAPFilter, $Properties, $SearchBase, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'New-ADUser'                     = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Name, $GivenName, $Surname, $DisplayName, $SamAccountName, $UserPrincipalName, $Path,
            $Department, $Title, $Office, $Manager, $AccountPassword, $ChangePasswordAtLogon, $Enabled,
            [switch]$PassThru, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Set-ADUser'                     = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Description, $Department, $Title, $Manager, $Office, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Disable-ADAccount'              = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, [switch]$PassThru, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Move-ADObject'                  = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $TargetPath, [switch]$PassThru, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Get-ADPrincipalGroupMembership' = {
        [CmdletBinding()]
        param($Identity, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Add-ADGroupMember'              = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Members, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Remove-ADGroupMember'           = {
        [CmdletBinding(SupportsShouldProcess)]
        param($Identity, $Members, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Get-ADComputer'                 = {
        [CmdletBinding()]
        param($Identity, $Filter, $LDAPFilter, $Properties, $SearchBase, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
    'Get-ADDomainController'         = {
        [CmdletBinding()]
        param($Identity, [switch]$Discover, [switch]$Writable, $DomainName, $Server, $Credential)
        throw "AD stub '$($MyInvocation.MyCommand.Name)' was called without a mock."
    }
}
$TestDomainController = 'dc01.corp.example'
$AdCommandNames = @($AdStubDefinitions.Keys)
$AdWriteCommandNames = @($AdCommandNames | Where-Object { $_ -notlike 'Get-*' })

foreach ($stubName in $AdCommandNames) {
    if (-not (Get-Command -Name $stubName -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:global:$stubName" -Value $AdStubDefinitions[$stubName]
    }
}

function Register-AdDefaultMock {
    # Must be the first Mock of each AD command in a test file: Pester builds the mock's
    # parameter signature once, from the first Mock, and reuses it for later ones.
    # -RemoveParameterType matters only where RSAT is installed and the real cmdlets are mocked:
    # their -Identity/-Members/-Manager are typed (ADUser, ADGroup, ...), which would turn the
    # strings the module passes into AD objects and break ParameterFilters such as
    # { $Identity -eq 'CN=...' }. With the untyped stubs it changes nothing.
    foreach ($commandName in $AdCommandNames) {
        Mock -CommandName $commandName -ModuleName 'AdLifecycle' -MockWith { } -RemoveParameterType 'Identity', 'Members', 'Manager'
    }
    Mock -CommandName 'Get-ADDomainController' -ModuleName 'AdLifecycle' -MockWith {
        [pscustomobject]@{ HostName = @('dc01.corp.example'); Name = 'DC01' }
    }
}

# Runs a command and separates what it wrote to the error stream from its output.
# -ErrorVariable is not used on purpose: it also collects exceptions that the module catches and
# handles internally, which would make error counts meaningless.
# Pass -ErrorAction Continue explicitly to the command under test, so the result does not depend
# on the caller's $ErrorActionPreference (GitHub Actions sets it to 'Stop').
function Invoke-Captured {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $records = @(& $ScriptBlock 2>&1)
    [pscustomobject]@{
        Output = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        Errors = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    }
}

function New-TestAdGroup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Rid
    )
    [pscustomobject]@{
        Name              = $Name
        SamAccountName    = $Name
        DistinguishedName = "CN=$Name,OU=Groups,OU=Corp,DC=corp,DC=example"
        SID               = "S-1-5-21-1004336348-1177238915-682003330-$Rid"
    }
}

function ConvertFrom-TestSecureString {
    param([Parameter(Mandatory)][securestring]$SecureString)
    [System.Net.NetworkCredential]::new('', $SecureString).Password
}
