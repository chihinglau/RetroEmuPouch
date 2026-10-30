<#
.SYNOPSIS
    Verify a GamePouch HAP does NOT bundle any copyrighted ROM / BIOS content.

.DESCRIPTION
    Commercial distribution must not ship game ROMs or arcade BIOS files
    (e.g. neogeo.zip). The emulator cores are libretro .so libraries and are
    EXPECTED — they are not flagged. This script lists the bundled cores for
    confirmation and fails if any suspicious content is found.

    Mirrors scripts/check-apk-content.ps1 but for the OHOS .hap package.

.PARAMETER Hap
    Path to the HAP to inspect. Defaults to the newest *.hap under app/build/ohos.

.EXAMPLE
    pwsh -File scripts/check-hap-content.ps1
    pwsh -File scripts/check-hap-content.ps1 -Hap app/build/ohos/hap/entry-default-unsigned.hap
#>
param(
    [string]$Hap
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')

if (-not $Hap) {
    $Hap = Get-ChildItem -Path (Join-Path $root 'app/build/ohos') -Recurse -Filter *.hap -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Hap) { Write-Error "No HAP found under app/build/ohos"; exit 2 }
if (-not (Test-Path $Hap)) { Write-Error "HAP not found: $Hap"; exit 2 }

# Locate jar from the bundled JDK to read the HAP (a zip) entry list.
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

Write-Host "Scanning: $Hap" -ForegroundColor Cyan
$entries = & $jar tf $Hap
if ($LASTEXITCODE -ne 0) { Write-Error "jar tf failed (exit $LASTEXIT_CODE)"; exit 2 }

# Expected: libretro emulator cores (not content, never flagged).
$coreRe = 'libgs_.*\.so$'

# Suspicious content = game/BIOS archives anywhere in the package.
$suspiciousRe = @(
    'assets/.*\.(zip|rom|iso|cue|chd|7z|rar|gz)$',
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
Write-Host "`nFAIL: suspicious content found in HAP:" -ForegroundColor Red
$hits | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
exit 1
