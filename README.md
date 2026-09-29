# AdLifecycle

[![CI](https://github.com/JimmyAlter/ad-lifecycle/actions/workflows/ci.yml/badge.svg)](https://github.com/JimmyAlter/ad-lifecycle/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/JimmyAlter/ad-lifecycle)](https://github.com/JimmyAlter/ad-lifecycle/releases)
[![Coverage gate](https://img.shields.io/badge/coverage%20gate-90%25%20in%20CI-brightgreen)](#testing)

A PowerShell module for the joiner / mover / leaver lifecycle of on-premises Active Directory
accounts, plus a stale-computer report. It is built around guardrails rather than features:
nothing is written to AD unless you confirm, every write can be previewed with `-WhatIf`, and
the rules (OUs, groups, UPN suffix) live in a validated configuration file instead of in the code.

Written from scratch for this public repository, based on the joiner / mover / leaver patterns I
run in production. Public history starts at v0.1.0 (September 2026); see the
[changelog](CHANGELOG.md). The domain (`corp.example`), OUs and groups in this repository are
fictional.

## Quick start in 60 seconds

```powershell
git clone https://github.com/JimmyAlter/ad-lifecycle.git
cd ad-lifecycle
Import-Module .\AdLifecycle\AdLifecycle.psd1

# Offline, no AD needed: validate the example configuration (no output = valid).
Test-AdLifecycleConfig -Path .\examples\lifecycle.config.psd1
```

Then copy `examples\lifecycle.config.psd1`, put your own UPN suffix, OUs and groups in it, and
preview a joiner. `-WhatIf` only reads from AD (a writable DC lookup and the name-collision
check), so it needs RSAT and a domain account, but it changes nothing:

```text
PS> New-AdLifecycleUser -GivenName 'Lucía' -Surname 'Muñoz' -Department Finance -Site Madrid -Title Accountant -ConfigPath .\my.config.psd1 -WhatIf

What if: Performing the operation "Create user 'Lucía Muñoz' in 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example' and add to 6 group(s): GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW, GG-App-ERP, GG-Reporting-Read" on target "lmunoz@corp.example".

SamAccountName    : lmunoz
UserPrincipalName : lmunoz@corp.example
DisplayName       : Lucía Muñoz
OU                : OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example
DistinguishedName :
Department        : Finance
Site              : Madrid
Title             : Accountant
Manager           :
Groups            : {GG-All-Staff, GG-VPN-Users, GG-Finance, GG-Share-Finance-RW...}
FailedGroups      : {}
InitialPassword   :
Applied           : False
```

(Windows PowerShell 5.1, example configuration, no `lmunoz` in AD yet.) Drop `-WhatIf` and
PowerShell asks for confirmation before creating anything. The same `-WhatIf` preview works for
`Set-AdLifecycleUser` and `Disable-AdLifecycleUser`.

## Commands

| Command | Stage | Changes AD |
| --- | --- | --- |
| `New-AdLifecycleUser` | Joiner | Yes, after confirmation. Creates the account from the site and department templates. |
| `Set-AdLifecycleUser` | Mover | Yes, after confirmation. Applies the group difference between two department templates, and moves the account to another site OU, sets title and manager. Alias: `Set-AdLifecycleDepartment`. |
| `Disable-AdLifecycleUser` | Leaver | Yes, after confirmation. Disables, records and removes group memberships, tags with the ticket, moves to the disabled OU. |
| `Get-AdStaleComputer` | Hygiene | No. Lists computers that have neither logged on nor changed their machine password for N days. |
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
- **Refuse the dangerous targets.** The leaver never offboards the built-in Administrator,
  krbtgt or the account running it, and needs `-Force` for protected accounts (`adminCount = 1`
  or members of Domain, Schema or Enterprise Admins or `BUILTIN\Administrators`, also nested).
  Re-running it on an account that is already offboarded changes nothing.
- **Audit trail.** With `-LogPath`, every change is appended as one JSON line (who, when, which
  DC, ticket, what was planned, what failed), without passwords.
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
- An account allowed to create users in the site OUs, manage the groups in the templates, update
  user attributes (Department, Title, Manager, Office, Description), disable accounts, and move
  users between site OUs and into the disabled OU.

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
PS> Set-AdLifecycleUser -Identity jpena -Department Sales -WhatIf

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
that attribute is empty or wrong. Every template group involved is resolved first; if one does
not exist, nothing is changed for that user.

A full internal transfer (department, site, title, manager) is one command and one
confirmation. Only what differs is written: groups are added, then removed, then one
`Set-ADUser` sets the attributes (`Department`, `Title`, `Manager`, `Office` = site name), and the
account is moved to the new site's OU last:

```text
PS> Set-AdLifecycleUser -Identity jpena -Department Sales -Site Cordoba -Title 'Account Executive' -Manager mlopez -WhatIf

What if: Performing the operation "Change department 'Finance' -> 'Sales'; add to: GG-Sales, GG-Share-Sales-RW, GG-App-CRM; remove from: GG-Finance, GG-Share-Finance-RW; set Title 'Account Executive'; set Manager 'CN=Marta Lopez,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'; set Office 'Cordoba'; move to 'OU=Users,OU=Cordoba,OU=Sites,OU=Corp,DC=corp,DC=example'" on target "jpena (CN=Jose Pena,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example)".
```

`-Department`, `-Site`, `-Title` and `-Manager` are each optional, but at least one is required.
The mover uses the leaver's guard: it refuses the built-in Administrator and krbtgt, and
protected accounts (`adminCount = 1`, privileged group members) unless `-Force` is given.
`Set-AdLifecycleDepartment`, the 0.1.0 name of this command, still works as an alias.

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
Administrator (RID 500), krbtgt (RID 502) and the account running it: the current Windows user
and the `-Credential` account, which is looked up in AD once (by UPN, or by `sAMAccountName`
for `DOMAIN\name`) and compared by SID. Protected accounts need `-Force`: `adminCount = 1`, or
membership, also nested (`tokenGroups`), of Domain Admins, Schema Admins, Enterprise Admins or
BUILTIN\Administrators. An account that is already disabled and already in
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

With `-ResetPassword`, the leaver also sets a random 64-character password right after
disabling the account (same confirmation). The new password is generated, set and discarded: it
is not returned, printed or logged, so a re-enabled account cannot be used with the old one.
`PasswordReset` in the result says whether it happened.

### Stale computers

```powershell
Get-AdStaleComputer -Days 120 |
    Sort-Object DaysInactive -Descending |
    Format-Table Name, LastLogonUtc, DaysInactive, DaysSincePasswordSet, NeverLoggedOn, OperatingSystem
```

Uses two signals, both converted from FILETIME to UTC: `lastLogonTimestamp` and `pwdLastSet`
(domain members change their machine password every 30 days by default). A computer is
reported only when both are older than `-Days`, so a machine whose logon timestamp lags but
that still rotates its password is not flagged. `-LastLogonOnly` uses `lastLogonTimestamp`
alone. Computers that never logged on are listed only if they were created before the cutoff
(so yesterday's pre-staged machines do not show up) and are flagged with `NeverLoggedOn`. It
only reports; what to do with the list is up to you.

### Audit log

With `-LogPath` (or `LogPath` in the configuration), the joiner, mover and leaver append one JSON
line per user they change (JSON Lines, UTF-8 without BOM), after the change, including partial
failures and a failed create or disable. Nothing is logged under `-WhatIf`, and initial
passwords are never logged. `-Ticket` is mandatory for the leaver and optional for the joiner
(also from a `Ticket` CSV column) and the mover.

```powershell
New-AdLifecycleUser -GivenName 'Lucía' -Surname 'Muñoz' -Department Finance -Site Madrid -Title Accountant `
    -Ticket RITM0001 -LogPath C:\ops\logs\ad-lifecycle.jsonl
Get-Content C:\ops\logs\ad-lifecycle.jsonl | ConvertFrom-Json | Where-Object Ticket -EQ 'RITM0001'
```

Each line has `TimestampUtc`, `Operator` (the Windows user), `CredentialUser` (with
`-Credential`), `Server`, `Command`, `Target`, `DistinguishedName`, `Ticket`, `Changes` (what was
planned: groups, OU, attributes), `Applied`, `FailedGroups` and `Errors`. A joiner line looks like
this (wrapped here):

```json
{"TimestampUtc":"2026-09-28T13:05:12.418Z","Operator":"CORP\\it.admin","CredentialUser":null,
 "Server":"dc01.corp.example","Command":"New-AdLifecycleUser","Target":"lmunoz",
 "DistinguishedName":"CN=Lucía Muñoz,OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example",
 "Ticket":"RITM0001","Changes":{"SamAccountName":"lmunoz","UserPrincipalName":"lmunoz@corp.example",
 "DisplayName":"Lucía Muñoz","OU":"OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example",
 "Department":"Finance","Site":"Madrid","Title":"Accountant","Manager":null,
 "Groups":["GG-All-Staff","GG-VPN-Users","GG-Finance","GG-Share-Finance-RW","GG-App-ERP","GG-Reporting-Read"]},
 "Applied":true,"FailedGroups":[],"Errors":[]}
```

The folder must exist; if it does not, the command stops before touching AD. If a line cannot be
written after a change was made, the command writes a warning (not an error), so the joiner still
returns the initial password.

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
| `LogPath` | No | Audit log file (JSON Lines). `-LogPath` overrides it. |

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

The Pester 5 suite is the main point of this repository (251 tests; Pester reports about 98% of
the module's commands covered on Windows PowerShell 5.1, and CI fails below 90%). It proves,
without any domain controller:

- **`-WhatIf` performs zero writes** for all three commands that change AD
  (`Should -Invoke New-ADUser -Times 0`, and the same for every other write cmdlet), and
  `-Confirm:$false` makes exactly the expected calls with the expected OU, UPN, groups and DNs.
- **One DC per run:** every read and write of a run carries the same `-Server` (discovered once,
  or given), and `-Credential` is passed through.
- **Leaver:** `-Ticket` is mandatory and validated; RID 500, RID 502, the caller's own account
  (also a `-Credential` given as a UPN), `adminCount = 1` and privileged group members (without
  `-Force`) are refused; already-offboarded accounts are skipped;
  Domain Users and the primary group are kept (also when localized); memberships come from
  `memberOf` and are exported before the first write; a failed disable stops everything else; a
  failed CSV write changes nothing.
- **Audit log:** one JSON line per change with the expected fields, never the password, nothing
  under `-WhatIf`, still written when `-ErrorAction Stop` interrupts a leaver.
- **Mover:** the Added / Removed / Unchanged diff, that only real changes are applied, site
  moves, title and manager in one `Set-ADUser` call, the order of the steps, and the 0.1.0 alias.
- **Joiner:** name generation (Spanish and other diacritics, apostrophes, hyphens, 20-character
  truncation, collisions on sAMAccountName or UPN, no duplicates within one run), and that the
  password is still returned when a group add fails, even under `-ErrorAction Stop`.
- **Passwords:** SecureString only, read-only, length, character classes on 500 samples,
  uniqueness, allowed alphabet.
- **Stale computers:** FILETIME conversion against a known value, threshold boundaries, the
  `pwdLastSet` signal (and `-LastLogonOnly`), never-logged-on handling, the LDAP filter sent to
  AD.
- **Configuration:** each broken case (26 of them) is reported; data files containing code are
  rejected without being executed.
- **Module hygiene:** the manifest is valid, exports exactly the functions in `Public/`, has no
  `RequiredModules`, imports in a fresh session without the AD module; every public function has
  help for every parameter; files with non-ASCII characters are UTF-8 with BOM (Windows
  PowerShell 5.1 reads BOM-less files as ANSI and would turn `Muñoz` into mojibake).

**How AD is faked.** `tests/TestHelpers.ps1` defines a stub function for each AD cmdlet the module
uses (`Get-ADUser`, `New-ADUser`, `Add-ADGroupMember`, ...) only when the real one is missing,
then mocks all of them inside the module's scope with `Mock -ModuleName AdLifecycle`. Reads
return nothing (except `Get-ADDomainController`, which returns a fictional `dc01.corp.example`)
and writes do nothing unless a test says otherwise, so even on a machine that has
RSAT no test can reach a real directory, and a test fails if the module ever calls an AD cmdlet
that is not in that list. On machines with RSAT the mocks drop the AD parameter types
(`-RemoveParameterType`) so parameter filters compare plain strings.

Run everything (Pester 5 and PSScriptAnalyzer must be installed):

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
./build.ps1                 # tests + analyzer
./build.ps1 -Task Test -CI  # also NUnit results + JaCoCo coverage in ./testResults; fails below 90%
```

CI runs the suite on Windows PowerShell 5.1 and PowerShell 7 on Windows, and PowerShell 7 on
Linux. PSScriptAnalyzer runs on both Windows shells over the module, the examples and
`build.ps1`, and fails the build on any Error or Warning (`PSScriptAnalyzerSettings.psd1`; there
is one suppression, with its justification, on `New-AdInitialPassword`). Each test job also
posts a table with the test count and the coverage to the run's summary page.

## Limitations

- On-premises Active Directory only. No Entra ID, Exchange or licensing, and no Google Workspace
  provisioning (I handle that separately; it is not part of this module).
- The `sAMAccountName` rule is fixed. Names with no Latin letters at all are rejected with an
  error rather than guessed. Two people with the same full name in the same site OU will make
  `New-ADUser` fail on the duplicate CN; nothing is created in that case.
- The mover applies a template diff; it is not a reconciler.
- The leaver does not handle mailboxes, home folders or licenses, and does not set
  `AccountExpirationDate` (disable, plus `-ResetPassword` if wanted, is the offboarding state).
- `lastLogonTimestamp` is replicated with a delay of up to 14 days by default, so stale-computer
  results are not precise for short windows.
- Tested with mocks. The suite has not been run against a live domain in CI.

## License

[MIT](LICENSE)
