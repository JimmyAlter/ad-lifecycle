<#
.SYNOPSIS
    Runs the Pester test suite and/or PSScriptAnalyzer for the AdLifecycle module.

.DESCRIPTION
    Needs Pester 5.x and PSScriptAnalyzer 1.21 or later, either installed or already imported
    into the session. Does not install anything. Throws (non-zero exit code) on any failing test
    or on any analyzer Error/Warning.

    Install the prerequisites once with:
        Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -SkipPublisherCheck
        Install-Module PSScriptAnalyzer -Scope CurrentUser

.PARAMETER Task
    All (default), Test or Analyze.

.PARAMETER CI
    Also write NUnit test results and JaCoCo code coverage to ./testResults.

.EXAMPLE
    ./build.ps1

.EXAMPLE
    ./build.ps1 -Task Test -CI
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Test', 'Analyze')]
    [string]$Task = 'All',

    [switch]$CI
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Invoke-TestTask {
    param([switch]$WriteResults)

    $pester = Get-Module -Name Pester | Where-Object { $_.Version.Major -eq 5 }
    if (-not $pester) {
        Get-Module -Name Pester | Remove-Module -Force
        Import-Module -Name Pester -MinimumVersion 5.0 -MaximumVersion 5.99.99 -ErrorAction Stop
        $pester = Get-Module -Name Pester
    }
    Write-Output ('Pester {0} on PowerShell {1} ({2})' -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $root 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'

    if ($WriteResults) {
        $resultsDir = Join-Path $root 'testResults'
        New-Item -Path $resultsDir -ItemType Directory -Force | Out-Null
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = Join-Path $resultsDir 'pester.xml'
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = @(Join-Path $root 'AdLifecycle')
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
        $configuration.CodeCoverage.OutputPath = Join-Path $resultsDir 'coverage.xml'
    }

    $result = Invoke-Pester -Configuration $configuration
    if ($result.Result -ne 'Passed') {
        throw ('Pester: {0} failed, {1} passed, {2} skipped; {3} block(s) and {4} container(s) failed.' -f
            $result.FailedCount, $result.PassedCount, $result.SkippedCount, $result.FailedBlocksCount, $result.FailedContainersCount)
    }
    Write-Output ('Pester: {0} passed, {1} failed, {2} skipped.' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
}

function Invoke-AnalyzeTask {
    if (-not (Get-Module -Name PSScriptAnalyzer)) {
        Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.21 -ErrorAction Stop
    }
    Write-Output ('PSScriptAnalyzer {0}' -f (Get-Module -Name PSScriptAnalyzer).Version)

    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # The tests are not analyzed: Pester's BeforeAll/It scoping and the AD stubs trip
    # PSUseDeclaredVarsMoreThanAssignments and PSReviewUnusedParameter by design.
    $targets = @(
        Join-Path $root 'AdLifecycle'
        Join-Path $root 'examples'
        Join-Path $root 'build.ps1'
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $findings = @(foreach ($target in $targets) {
            Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $settings
        })

    if ($findings.Count -gt 0) {
        $findings | Format-Table -Property Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
        throw ('PSScriptAnalyzer: {0} finding(s).' -f $findings.Count)
    }
    Write-Output 'PSScriptAnalyzer: 0 findings (Error/Warning).'
}

if ($Task -in 'All', 'Test') {
    Invoke-TestTask -WriteResults:$CI
}
if ($Task -in 'All', 'Analyze') {
    Invoke-AnalyzeTask
}
