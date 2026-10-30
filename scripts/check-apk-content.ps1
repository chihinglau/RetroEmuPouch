<#
.SYNOPSIS
    Verify a GamePouch APK does NOT bundle any copyrighted ROM / BIOS content.

.DESCRIPTION
    Commercial distribution must not ship game ROMs or arcade BIOS files
    (e.g. neogeo.zip). The emulator cores are libretro .so libraries under
    lib/<abi>/ and are EXPECTED — they are not flagged. This script lists the
    bundled cores for confirmation and fails if any suspicious content is found.

.PARAMETER Apk
    Path to the APK to inspect. Defaults to the store release output.

.EXAMPLE
    pwsh -File scripts/check-apk-content.ps1
    pwsh -File scripts/check-apk-content.ps1 -Apk app/build/.../app-store-release.apk
#>
param(
    [string]$Apk = "app/build/app/outputs/flutter-apk/app-store-release.apk"
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not (Split-Path $Apk -IsAbsolute)) { $Apk = Join-Path $root $Apk }
if (-not (Test-Path $Apk)) { Write-Error "APK not found: $Apk"; exit 2 }

# Locate jar from the bundled JDK to read the APK (a zip) entry list.
$candidates = @(
    (Join-Path $root '.tools/jdk21/bin/jar.exe'),
    (Join-Path $root '.tools/jdk17/bin/jar.exe')
)
$jar = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $jar) {
    $cmd = Get-Command jar.exe -ErrorAction SilentlyContinue
    if ($cmd) { $jar = $cmd.Source }
}
if (-not $jar) { Write-Error "jar.exe not found under .tools/jdk*/bin or PATH"; exit 2 }

Write-Host "Scanning: $Apk" -ForegroundColor Cyan
$entries = & $jar tf $Apk
if ($LASTEXITCODE -ne 0) { Write-Error "jar tf failed (exit $LASTEXIT_CODE)"; exit 2 }

# Expected: libretro emulator cores (not content, never flagged).
$coreRe = 'lib/[^/]+/libgs_.*\.so$'

# Suspicious content = game/BIOS archives under app assets, or known BIOS
# filenames anywhere in the package.
$suspiciousRe = @(
    'assets/.*\.(zip|rom|iso|cue|chd|7z|rar|gz)$',           # content in assets
    'neogeo', 'neocdz', 'uni-?bios', 'sp1\.', 'sfix', 'sm1_',
    'qsound', 'cpzn1', 'cpzn2', 'cps1', 'cps2', 'pgm', 'skns',
    'gamegenie', '[^a-z]bios[^a-z]'
) -join '|'

$cores = [System.Collections.Generic.List[string]]::new()
$hits  = [System.Collections.Generic.List[string]]::new()
foreach ($e in $entries) {
    if ($e -match $coreRe) { $cores.Add($e); continue }
    if ($e -match $suspiciousRe) { $hits.Add($e) }
}

Write-Host "`nBundled emulator cores (expected, must NOT be flagged):" -ForegroundColor Green
if ($cores.Count -eq 0) {
    Write-Host "  (none found — verify the build packaged cores at all)" -ForegroundColor Yellow
} else {
    $cores | Sort-Object | ForEach-Object { Write-Host "  $_" }
}

if ($hits.Count -eq 0) {
    Write-Host "`nPASS: no bundled ROM/BIOS content detected." -ForegroundColor Green
    exit 0
}
Write-Host "`nFAIL: suspicious content found in APK:" -ForegroundColor Red
$hits | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
exit 1
