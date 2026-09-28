# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the major
version is 0, a minor version may contain breaking changes; they are called out below.

## [Unreleased]

### Added

- Module manifest: `ProjectUri`, `LicenseUri`, `ReleaseNotes` and the `PSEdition_Desktop` /
  `PSEdition_Core` tags.
- `-Server` and `-Credential` on `New-AdLifecycleUser`, `Set-AdLifecycleDepartment`,
  `Disable-AdLifecycleUser` and `Get-AdStaleComputer`.

### Changed

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

[Unreleased]: https://github.com/JimmyAlter/ad-lifecycle/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JimmyAlter/ad-lifecycle/releases/tag/v0.1.0
