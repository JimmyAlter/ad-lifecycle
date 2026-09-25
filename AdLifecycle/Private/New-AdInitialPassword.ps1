function New-AdInitialPassword {
    <#
    .SYNOPSIS
        Generates a random initial password and returns it only as a read-only SecureString.

    .DESCRIPTION
        - Randomness comes from System.Security.Cryptography.RandomNumberGenerator, with rejection
          sampling so every character is picked without modulo bias.
        - Complexity is guaranteed, not hoped for: one uppercase letter, one lowercase letter, one
          digit and one symbol are always included, the rest is drawn from the full set, and the
          result is shuffled (Fisher-Yates) with the same generator.
        - Look-alike characters (I, O, l, 0, 1) are excluded because someone has to read the
          password to the new hire.
        - The password never exists as a System.String: characters go from a char[] straight into
          the SecureString, and the buffer is cleared afterwards.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Only builds an in-memory SecureString; no system state is changed.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16
    )

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '!#%*+-=?@_'
    $all = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = [byte[]]::new(4)
    $chars = [char[]]::new($Length)

    # Uniform integer in [0, ExclusiveMax): draw 32 random bits and reject the values that fall in
    # the incomplete last bucket, so that "value % ExclusiveMax" has no bias.
    $nextIndex = {
        param([int]$ExclusiveMax)
        $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$ExclusiveMax)
        do {
            $rng.GetBytes($buffer)
            $value = [System.BitConverter]::ToUInt32($buffer, 0)
        } while ($value -ge $limit)
        [int]($value % $ExclusiveMax)
    }

    try {
        $chars[0] = $upper[(& $nextIndex $upper.Length)]
        $chars[1] = $lower[(& $nextIndex $lower.Length)]
        $chars[2] = $digits[(& $nextIndex $digits.Length)]
        $chars[3] = $symbols[(& $nextIndex $symbols.Length)]
        for ($i = 4; $i -lt $Length; $i++) {
            $chars[$i] = $all[(& $nextIndex $all.Length)]
        }

        for ($i = $Length - 1; $i -gt 0; $i--) {
            $j = & $nextIndex ($i + 1)
            $swap = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $swap
        }

        $secure = [System.Security.SecureString]::new()
        foreach ($char in $chars) {
            $secure.AppendChar($char)
        }
        $secure.MakeReadOnly()
        $secure
    } finally {
        [Array]::Clear($chars, 0, $chars.Length)
        [Array]::Clear($buffer, 0, $buffer.Length)
        $rng.Dispose()
    }
}
