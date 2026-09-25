# PSScriptAnalyzer settings used locally (./build.ps1 -Task Analyze) and in CI.
# The build fails on any Error or Warning. Suppressions, if any, live next to the code they
# apply to, as [Diagnostics.CodeAnalysis.SuppressMessageAttribute] with a Justification.
@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true

    Rules               = @{
        # The module targets Windows PowerShell 5.1 and PowerShell 7.
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        # One brace style (OTBS) and one indentation style everywhere.
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace  = @{
            Enable          = $true
            CheckInnerBrace = $true
            CheckOpenBrace  = $true
            CheckOpenParen  = $true
            CheckOperator   = $false
            CheckPipe       = $true
            CheckSeparator  = $true
            CheckParameter  = $false
        }
    }
}
