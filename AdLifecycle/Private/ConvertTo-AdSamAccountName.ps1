function ConvertTo-AdSamAccountName {
    <#
    .SYNOPSIS
        Builds a sAMAccountName candidate from a given name and a surname.

    .DESCRIPTION
        Pure string function, no Active Directory calls. The rules:

        - first letter of the given name + the whole surname
        - lowercase; diacritics removed (a-acute -> a, n-tilde -> n, u-umlaut -> u)
        - letters that Unicode normalization does not split are transliterated
          (sharp s -> ss, o-stroke -> o, l-stroke -> l, ae/oe ligatures -> ae/oe, ...)
        - everything except a-z and 0-9 is dropped (spaces, apostrophes, hyphens, dots)
        - truncated so the result, including the optional numeric suffix, fits MaxLength
          (20 = the pre-Windows 2000 logon name limit)

        Collision handling (appending 2, 3, ...) lives in Resolve-AdSamAccountName.

        The module source is kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less
        files as ANSI), so non-ASCII characters are referenced here by code point.

    .EXAMPLE
        ConvertTo-AdSamAccountName -GivenName 'Sean' -Surname "O'Neill"

        Returns 'soneill'.

    .EXAMPLE
        ConvertTo-AdSamAccountName -GivenName 'Ana' -Surname 'de la Fuente' -Suffix 2

        Returns 'adelafuente2'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$GivenName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Surname,

        # Collision suffix (2, 3, ...). Omit it for the first candidate.
        [ValidateRange(2, 999)]
        [int]$Suffix,

        [ValidateRange(3, 20)]
        [int]$MaxLength = 20
    )

    # Lowercase letters that FormD normalization leaves intact (no base letter + combining mark).
    $transliteration = @{
        0x00DF = 'ss' # sharp s
        0x00E6 = 'ae' # ae ligature
        0x00F0 = 'd'  # eth
        0x00F8 = 'o'  # o with stroke
        0x00FE = 'th' # thorn
        0x0111 = 'd'  # d with stroke
        0x0131 = 'i'  # dotless i
        0x0142 = 'l'  # l with stroke
        0x0153 = 'oe' # oe ligature
    }

    $normalize = {
        param([string]$Text)

        $decomposed = $Text.ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormD)
        $builder = [System.Text.StringBuilder]::new($decomposed.Length)
        foreach ($char in $decomposed.ToCharArray()) {
            $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
            if ($category -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                continue
            }

            $code = [int]$char
            if ($transliteration.ContainsKey($code)) {
                [void]$builder.Append($transliteration[$code])
            } elseif (($code -ge 0x61 -and $code -le 0x7A) -or ($code -ge 0x30 -and $code -le 0x39)) {
                # a-z or 0-9
                [void]$builder.Append($char)
            }
        }
        $builder.ToString()
    }

    $givenPart = & $normalize $GivenName
    $surnamePart = & $normalize $Surname
    if (-not $givenPart -or -not $surnamePart) {
        $template = "Cannot derive a sAMAccountName from '{0} {1}': no letters a-z or digits remain after normalization."
        throw ($template -f $GivenName, $Surname)
    }

    $suffixText = ''
    if ($PSBoundParameters.ContainsKey('Suffix')) {
        $suffixText = [string]$Suffix
    }

    $name = $givenPart.Substring(0, 1) + $surnamePart
    $maxBaseLength = $MaxLength - $suffixText.Length
    if ($name.Length -gt $maxBaseLength) {
        $name = $name.Substring(0, $maxBaseLength)
    }

    $name + $suffixText
}
