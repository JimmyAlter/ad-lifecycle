# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the major
version is 0, a minor version may contain breaking changes; they are called out below.

## [Unreleased]

## [0.3.1] - 2026-09-29

### Changed

- Leaver: a `-Credential` account that is not in the target domain (for example from a trusted
  domain) no longer stops the run. It cannot be one of the users the leaver reads and changes,
  all of which come from the target domain; a verbose message says so. A failing lookup still
  stops the run.

### Documentation

- README: `-ResetPassword` needs the "Reset password" permission; the `-Credential` lookup scope
  is described under Limitations.
- CHANGELOG 0.3.0: the mover's new guard is listed under Changed as a possibly breaking change.

## [0.3.0] - 2026-09-29

### Fixed

- Leaver: the self-offboarding guard missed a `-Credential` given as a UPN whose prefix is not
  the sAMAccountName. The credential account is now looked up in AD once per run (by UPN, or by
  sAMAccountName) and compared by SID; the run stops if it cannot be found.

### Added

- Leaver: members of Domain Admins, Schema Admins, Enterprise Admins or BUILTIN\Administrators
  (direct, nested via `tokenGroups`, or as primary group) are refused unless `-Force`, like
  `adminCount = 1`.
- Mover: `Set-AdLifecycleUser` applies the same guard (RID 500 and 502 always refused;
  protected accounts only with the new `-Force`).
- Leaver: `-ResetPassword` sets a random 64-character password after disabling, under the same
  confirmation; it is discarded (never returned, printed or logged). New `PasswordReset` property
  on `AdLifecycle.LeaverResult` and `ResetPassword` in the audit log.

### Changed

- **Possibly breaking:** `Set-AdLifecycleUser` (and its alias `Set-AdLifecycleDepartment`) now
  refuses accounts with `adminCount = 1` or in Domain Admins, Schema Admins, Enterprise Admins
  or BUILTIN\Administrators unless `-Force` is given, and always refuses RID 500 and 502. Scripts
  that moved such accounts with 0.2.0 must add `-Force`.
- Joiner: when the sAMAccountName needs a numeric suffix, the object name (CN) is
  `Display Name (sam)` so a namesake in the same OU no longer makes `New-ADUser` fail on a
  duplicate CN. The display name is unchanged.
- CI: GitHub Actions are pinned to commit SHAs (version in a comment).
- `.mailmap` maps the earlier author name to Thiago Langone.
- README: the full-transfer mover example now shows the real output (it left out GG-App-ERP).

## [0.2.0] - 2026-09-28

### Added

- Module manifest: `ProjectUri`, `LicenseUri`, `ReleaseNotes` and the `PSEdition_Desktop` /
  `PSEdition_Core` tags.
- `-Server` and `-Credential` on `New-AdLifecycleUser`, `Set-AdLifecycleUser`,
  `Disable-AdLifecycleUser` and `Get-AdStaleComputer`.
- Leaver safety guard: `Disable-AdLifecycleUser` refuses the built-in Administrator (RID 500),
  krbtgt (RID 502) and the caller's own account (Windows identity or `-Credential` user), and
  accounts with `adminCount = 1` unless `-Force` is given.
- The leaver is idempotent: an account that is already disabled and in `DisabledOU` is skipped
  with a warning (new `Skipped` property on `AdLifecycle.LeaverResult`) instead of having its
  description, date and ticket overwritten.
- Mover: `-Site` (moves the account to the site's OU and sets `Office`), `-Title` and `-Manager`,
  all planned and confirmed together with the department change in a single `ShouldProcess`
  per user. `AdLifecycle.MoverResult` gains `PreviousTitle`, `Title`, `PreviousManager`,
  `Manager`, `PreviousOU` and `TargetOU`.
- Audit log: `-LogPath` on the joiner, mover and leaver (or `LogPath` in the configuration)
  appends one JSON line per user changed: UTC timestamp, operator, credential user, DC,
  command, target, ticket, planned changes, `Applied`, failed groups and errors. Never contains
  passwords; nothing is written under `-WhatIf`.
- Optional `-Ticket` on `New-AdLifecycleUser` (also from a `Ticket` CSV column) and
  `Set-AdLifecycleUser`, recorded in the audit log.
- CI fails when code coverage drops below 90% (`build.ps1 -CoverageTarget`, Pester
  `CoveragePercentTarget`) and writes a test and coverage summary to each job's summary page.

### Changed

- `Set-AdLifecycleDepartment` is renamed `Set-AdLifecycleUser`, since it now changes more than
  the department, and `-Department` is optional (at least one of `-Department`, `-Site`,
  `-Title`, `-Manager` is required). `Set-AdLifecycleDepartment` remains as an exported alias.
- `Get-AdStaleComputer` uses `pwdLastSet` as a second staleness signal: a computer is reported
  only when both `lastLogonTimestamp` and `pwdLastSet` are older than `-Days`. New output
  properties `PasswordLastSetUtc` and `DaysSincePasswordSet`; `-LastLogonOnly` restores the
  0.1.0 behaviour. This can report fewer computers than 0.1.0 did.
- The three write commands pin one writable domain controller per run
  (`Get-ADDomainController -Discover -Writable`, or `-Server`) and send every AD call to it. This
  fixes joiner group adds that could fail on a DC that had not replicated the new account yet.
- The leaver and the mover read group memberships from the user's `memberOf` (and, for the
  leaver, `primaryGroupID`) instead of `Get-ADPrincipalGroupMembership`, which fails for users
  in groups that contain foreign security principals. The mover now resolves every template
  group it adds or removes before changing anything, and stops for that user if one is missing.

## [0.1.0] - 2026-09-25

First public release.

### Added

- `New-AdLifecycleUser` (joiner): sAMAccountName and UPN built from the name (diacritics
  stripped, collision suffixes, no duplicates within one pipeline run), account created in the
  site OU with a cryptographically random initial password returned only as a SecureString,
  CommonGroups and department groups added.
- `Set-AdLifecycleDepartment` (mover): applies the Added / Removed difference between two
  department group templates and updates the Department attribute.
- `Disable-AdLifecycleUser` (leaver): mandatory `-Ticket`; records memberships (optionally to a
  CSV) before any change; disables, tags the description, removes every group except the primary
  group and Domain Users (matched by RID), moves the account to `DisabledOU`.
- `Get-AdStaleComputer`: read-only report based on `lastLogonTimestamp`.
- `Test-AdLifecycleConfig`: offline validation of the `.psd1` configuration file.
- Every write command supports `-WhatIf` / `-Confirm` with `ConfirmImpact = 'High'`.
- Pester 5 suite with the AD cmdlets stubbed and mocked; PSScriptAnalyzer; CI on Windows
  PowerShell 5.1, PowerShell 7 on Windows and PowerShell 7 on Linux.

[Unreleased]: https://github.com/JimmyAlter/ad-lifecycle/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/JimmyAlter/ad-lifecycle/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/JimmyAlter/ad-lifecycle/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/JimmyAlter/ad-lifecycle/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JimmyAlter/ad-lifecycle/releases/tag/v0.1.0
