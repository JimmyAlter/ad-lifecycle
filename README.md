# AdLifecycle

[![CI](https://github.com/JimmyAlter/ad-lifecycle/actions/workflows/ci.yml/badge.svg)](https://github.com/JimmyAlter/ad-lifecycle/actions/workflows/ci.yml)

A PowerShell module for the joiner / mover / leaver lifecycle of on-premises Active Directory
accounts, plus a stale-computer report. It is built around guardrails rather than features:
nothing is written to AD unless you confirm, every write can be previewed with `-WhatIf`, and
the rules (OUs, groups, UPN suffix) live in a validated configuration file instead of in the code.

This is a generalized, public version of the provisioning tooling I use day to day across
several AD domains. The domain (`corp.example`), OUs and groups in this repository are fictional.

## Commands

| Command | Stage | Changes AD |
| --- | --- | --- |
| `New-AdLifecycleUser` | Joiner | Yes, after confirmation. Creates the account from the site and department templates. |
| `Set-AdLifecycleDepartment` | Mover | Yes, after confirmation. Applies the group difference between two department templates. |
| `Disable-AdLifecycleUser` | Leaver | Yes, after confirmation. Disables, records and removes group memberships, tags with the ticket, moves to the disabled OU. |
| `Get-AdStaleComputer` | Hygiene | No. Lists computers that have not logged on for N days. |
| `Test-AdLifecycleConfig` | Config | No, and works offline. Validates a configuration file. |

Every command has comment-based help with examples: `Get-Help New-AdLifecycleUser -Full`.

## Design principles

- **Read-only by default.** Only three commands write, and all three declare
  `SupportsShouldProcess` with `ConfirmImpact = 'High'`, so PowerShell prompts before any change
  unless you pass `-Confirm:$false` (for unattended runs). `-WhatIf` prints the plan, returns it
  as an object (`Applied = $false`) and performs zero writes. The test suite asserts this for
  every write cmdlet of every command.
- **One confirmation per user**, describing everything that will happen to that account.
- **Record before destroy.** The leaver captures all group memberships in its output, and
  optionally in a CSV, before removing anything. If the CSV cannot be written, the account is
  not touched. If disabling fails, nothing else is changed.
- **Passwords only as SecureString.** Initial passwords come from
  `System.Security.Cryptography.RandomNumberGenerator` (unbiased, with guaranteed upper/lower/
  digit/symbol), never exist as a `System.String`, and are never printed or logged. The result
  object carries them as `InitialPassword` (SecureString).
- **Config-driven.** Site OUs, department groups, the UPN suffix and the disabled OU are in a
  `.psd1` data file, read with `Import-PowerShellDataFile` (no code in it is executed) and
  validated before any command does anything.
- **No `RequiredModules` on RSAT.** The module imports anywhere (CI, Linux, a laptop without
  RSAT). Commands that need Active Directory check for the `ActiveDirectory` module when they run
  and stop with a clear `NotInstalled` error (`ActiveDirectoryModuleMissing`) that says how to
  install it.
- **One domain controller per run.** The three write commands resolve one writable DC at the
  start (`Get-ADDomainController -Discover -Writable`), or use `-Server`, and send every read and
  write of the run to it, so a new account is never looked up or added to groups on a DC that has
  not replicated it yet. `-Credential` is passed to every call as well.
- **No silent partial failures.** When a step fails after the first write (a group, the move),
  the command reports it and lists it in `FailedGroups`. The joiner reports group failures as
  warnings rather than errors on purpose: the account already exists at that point, and a
  terminating error under `-ErrorAction Stop` would lose the only copy of the initial password.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x.
- The `ActiveDirectory` module (RSAT) on the machine that runs the commands:
  - Windows 10/11: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
  - Windows Server: `Install-WindowsFeature RSAT-AD-PowerShell`
- An account allowed to create users in the site OUs, manage the groups in the templates and move
  objects into the disabled OU.

## Install

```powershell
git clone https://github.com/JimmyAlter/ad-lifecycle.git
Import-Module .\ad-lifecycle\AdLifecycle\AdLifecycle.psd1
```

Or copy the `AdLifecycle` folder into a folder in `$env:PSModulePath`. The module is not
published to the PowerShell Gallery.

## Usage

Validate the configuration, then set it once for the session so you do not have to pass
`-ConfigPath` every time:

```powershell
Test-AdLifecycleConfig -Path C:\ops\lifecycle.config.psd1 -Strict
$PSDefaultParameterValues['*-AdLifecycle*:ConfigPath'] = 'C:\ops\lifecycle.config.psd1'
```

Every command that talks to AD accepts `-Server` and `-Credential`. Without `-Server`, the write
commands pin one writable domain controller for the whole run; `Get-AdStaleComputer` lets the AD
module choose. From a machine that is not joined to the domain, pass `-Server`.

### Joiner

```text
PS> New-AdLifecycleUser -GivenName 'Lucía' -Surname 'Muñoz' -Department Finance -Site Madrid -Title Accountant -WhatIf

What if: Performing the operation "Create user 'Lucía Muñoz' in 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' and add to 6 group(s): GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW, GG-App-ERP, GG-Reporting-Read" on target "lmunoz@corp.example".

SamAccountName    : lmunoz
UserPrincipalName : lmunoz@corp.example
OU                : OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example
Groups            : {GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW...}
Applied           : False
```

How the `sAMAccountName` is built: first initial + surname, lowercase, diacritics removed
(`Muñoz` becomes `munoz`, `Peña` becomes `pena`), letters such as `ß`/`ø`/`ł` transliterated,
everything except `a-z` and `0-9` dropped (spaces, apostrophes, hyphens), at most 20 characters.
If the name or its UPN is taken, `2`, `3`, ... is appended (truncating the base so the result
still fits in 20). The display name keeps the original spelling.

Without `-WhatIf`, PowerShell asks for confirmation, then creates the account (enabled, "must
change password at next logon") and adds it to the groups:

```powershell
$new = New-AdLifecycleUser -GivenName 'Lucía' -Surname 'Muñoz' -Department Finance -Site Madrid -Title Accountant -Manager mlopez
$new.InitialPassword          # System.Security.SecureString
# Hand it over through your usual secure channel, for example:
[System.Net.NetworkCredential]::new('', $new.InitialPassword).Password | Set-Clipboard
```

Bulk joiners from a CSV (`GivenName, Surname, Department, Site, Title, Manager`). Names handed
out earlier in the same run are not reused, even under `-WhatIf`:

```text
PS> Import-Csv .\examples\new-hires.csv -Encoding UTF8 | New-AdLifecycleUser -WhatIf | Format-Table SamAccountName, UserPrincipalName, Department, Site

SamAccountName       UserPrincipalName                 Department  Site
--------------       -----------------                 ----------  ----
lmunoz               lmunoz@corp.example               Finance     Madrid
jpena                jpena@corp.example                Engineering Buenos Aires
agomez               agomez@corp.example               Sales       Cordoba
mfernandezcastellano mfernandezcastellano@corp.example IT          Remote
```

### Mover

```text
PS> Set-AdLifecycleDepartment -Identity jpena -Department Sales -WhatIf

What if: Performing the operation "Change department 'Finance' -> 'Sales'; add to: GG-Sales, GG-Share-Sales-RW, GG-App-CRM; remove from: GG-Finance, GG-Share-Finance-RW, GG-App-ERP" on target "jpena (CN=Jose Pena,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example)".

FromDepartment : Finance
ToDepartment   : Sales
Added          : {GG-Sales, GG-Share-Sales-RW, GG-App-CRM}
Removed        : {GG-Finance, GG-Share-Finance-RW, GG-App-ERP}
Unchanged      : {GG-Reporting-Read}
```

Only groups in the two templates are touched; `CommonGroups` and anything granted by hand stay.
Groups the user already has are not re-added, and groups they do not have are not "removed".
The current department comes from the user's `Department` attribute; use `-FromDepartment` when
that attribute is empty or wrong.

### Leaver

```text
PS> Disable-AdLifecycleUser -Identity jpena -Ticket INC-4821 -WhatIf

What if: Performing the operation "Disable the account; set description 'Disabled 2026-09-25 by CORP\it.admin - ticket INC-4821'; remove from 6 group(s): GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW, GG-App-ERP, GG-Reporting-Read; keep Domain Users; move to 'OU=Disabled Users,OU=Corp,DC=corp,DC=example'" on target "jpena (CN=Jose Pena,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example)".

RemovedGroups : {GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW...}
KeptGroups    : {Domain Users}
TargetOU      : OU=Disabled Users,OU=Corp,DC=corp,DC=example
Applied       : False
```

`-Ticket` is mandatory. The leaver refuses, without changing anything, the built-in
Administrator (RID 500), krbtgt (RID 502) and the account running it (the current Windows user
or the `-Credential` account); accounts with `adminCount = 1` (current or former members of
protected groups) need `-Force`. An account that is already disabled and already in
`DisabledOU` is skipped with a warning (`Skipped = True`), so re-running a bulk CSV does not
overwrite the original description and ticket. The primary group and Domain Users are kept, matched by RID (the
`primaryGroupID` and 513) rather than by name, so it also works on localized domains
("Usuarios del dominio"). Memberships come from the user's `memberOf` and `primaryGroupID`
rather than `Get-ADPrincipalGroupMembership`, which fails outright for users in groups that
contain foreign security principals (members from trusted domains). For bulk leavers, keep a
record of what was removed:

```powershell
Import-Csv .\leavers.csv | Disable-AdLifecycleUser -ExportPath .\removed-memberships.csv
```

`leavers.csv` needs `SamAccountName` and `Ticket` columns. The export has one row per membership
(user, group name and DN, kept or removed, ticket, operator, timestamp) and is appended to.

### Stale computers

```powershell
Get-AdStaleComputer -Days 120 |
    Sort-Object DaysInactive -Descending |
    Format-Table Name, LastLogonUtc, DaysInactive, NeverLoggedOn, OperatingSystem
```

Uses `lastLogonTimestamp`, converted from FILETIME to UTC. Computers that never logged on are
listed only if they were created before the cutoff (so yesterday's pre-staged machines do not
show up) and are flagged with `NeverLoggedOn`. It only reports; what to do with the list is up
to you.

## Configuration

See [`examples/lifecycle.config.psd1`](examples/lifecycle.config.psd1). One file per domain.

| Setting | Required | Meaning |
| --- | --- | --- |
| `UpnSuffix` | Yes | New accounts get `<sAMAccountName>@<UpnSuffix>`. |
| `DisabledOU` | Yes | DN of the OU leavers are moved to. Must not be a site OU. |
| `Sites` | Yes | Site name = DN of the OU where that site's users are created. |
| `Departments` | Yes | Department name = list of group `sAMAccountName`s. |
| `CommonGroups` | No | Groups every joiner gets. Not touched by the mover. |
| `PasswordLength` | No | Initial password length, 12-128. Default 16. |

```powershell
@{
    UpnSuffix   = 'corp.example'
    DisabledOU  = 'OU=Disabled Users,OU=Corp,DC=corp,DC=example'
    Sites       = @{
        'Madrid' = 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
    }
    Departments = @{
        'Finance' = @('GG-Finance', 'GG-Share-Finance-RW', 'GG-App-ERP')
    }
}
```

`Test-AdLifecycleConfig` (and every command that writes, before it starts) checks that the
required settings exist, that every OU is a valid distinguished name, that every site has an OU,
that every department has at least one group, that `PasswordLength` is in range, and that there
are no unknown settings (typos). It returns one object per problem, or throws with `-Strict`. It
does not check that the OUs and groups exist in AD.

```text
PS> Test-AdLifecycleConfig -Path .\broken.config.psd1 | Format-Table Setting, Message

Setting             Message
-------             -------
DisabledOU          'Disabled Users' is not a valid OU distinguished name (OU=...,DC=...,DC=...).
Sites.Madrid        Site 'Madrid' has no OU.
Departments.Finance Has no groups. Every department needs at least one group.
```

## Testing

The Pester 5 suite is the main point of this repository (185 tests; Pester reports about 97% of
the module's commands covered on Windows PowerShell 5.1). It proves, without any domain
controller:

- **`-WhatIf` performs zero writes** for all three commands that change AD
  (`Should -Invoke New-ADUser -Times 0`, and the same for every other write cmdlet), and
  `-Confirm:$false` makes exactly the expected calls with the expected OU, UPN, groups and DNs.
- **Leaver:** `-Ticket` is mandatory and validated; Domain Users and the primary group are kept
  (also when localized); memberships are exported before the first write; a failed disable
  stops everything else; a failed CSV write changes nothing.
- **Mover:** the Added / Removed / Unchanged diff, and that only real changes are applied.
- **Joiner:** name generation (Spanish and other diacritics, apostrophes, hyphens, 20-character
  truncation, collisions on sAMAccountName or UPN, no duplicates within one run), and that the
  password is still returned when a group add fails, even under `-ErrorAction Stop`.
- **Passwords:** SecureString only, read-only, length, character classes on 500 samples,
  uniqueness, allowed alphabet.
- **Stale computers:** FILETIME conversion against a known value, threshold boundaries,
  never-logged-on handling, the LDAP filter sent to AD.
- **Configuration:** each broken case (24 of them) is reported; data files containing code are
  rejected without being executed.
- **Module hygiene:** the manifest is valid, exports exactly the functions in `Public/`, has no
  `RequiredModules`, imports in a fresh session without the AD module; every public function has
  help for every parameter; files with non-ASCII characters are UTF-8 with BOM (Windows
  PowerShell 5.1 reads BOM-less files as ANSI and would turn `Muñoz` into mojibake).

**How AD is faked.** `tests/TestHelpers.ps1` defines a stub function for each AD cmdlet the module
uses (`Get-ADUser`, `New-ADUser`, `Add-ADGroupMember`, ...) only when the real one is missing,
then mocks all of them inside the module's scope with `Mock -ModuleName AdLifecycle`. Reads
return nothing and writes do nothing unless a test says otherwise, so even on a machine that has
RSAT no test can reach a real directory, and a test fails if the module ever calls an AD cmdlet
that is not in that list. On machines with RSAT the mocks drop the AD parameter types
(`-RemoveParameterType`) so parameter filters compare plain strings.

Run everything (Pester 5 and PSScriptAnalyzer must be installed):

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
./build.ps1                 # tests + analyzer
./build.ps1 -Task Test -CI  # also writes NUnit results and JaCoCo coverage to ./testResults
```

CI runs the suite on Windows PowerShell 5.1 and PowerShell 7 on Windows, and PowerShell 7 on
Linux. PSScriptAnalyzer runs on both Windows shells over the module, the examples and
`build.ps1`, and fails the build on any Error or Warning (`PSScriptAnalyzerSettings.psd1`; there
is one suppression, with its justification, on `New-AdInitialPassword`).

## Limitations

- On-premises Active Directory only. No Entra ID, Exchange or licensing, and no Google Workspace
  provisioning (I handle that separately; it is not part of this module).
- The `sAMAccountName` rule is fixed. Names with no Latin letters at all are rejected with an
  error rather than guessed. Two people with the same full name in the same site OU will make
  `New-ADUser` fail on the duplicate CN; nothing is created in that case.
- The mover applies a template diff; it is not a reconciler. It does not move the user between
  site OUs.
- The leaver does not handle mailboxes, home folders or licenses.
- `lastLogonTimestamp` is replicated with a delay of up to 14 days by default, so stale-computer
  results are not precise for short windows.
- Tested with mocks. The suite has not been run against a live domain in CI.

## License

[MIT](LICENSE)
