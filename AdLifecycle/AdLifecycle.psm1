# Root module: dot-sources the private helpers, then the public functions, and exports only the
# public ones (the manifest's FunctionsToExport is the authoritative list; this is defence in depth
# for anyone importing the .psm1 directly).
#
# The ActiveDirectory module is intentionally not imported here. Commands that need it call
# Assert-AdModule when they run, so this module loads on machines without RSAT (CI, Linux, laptops).

$privateFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to load '$($file.FullName)': $($_.Exception.Message)"
    }
}

$publicNames = @($publicFiles | ForEach-Object { $_.BaseName })
if ($publicNames.Count -gt 0) {
    Export-ModuleMember -Function $publicNames
} else {
    Export-ModuleMember
}
