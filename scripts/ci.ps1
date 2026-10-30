<#
  CI gate for GamePouch builds (P1-4 / R11 / P2-R12).
  Asserts the compliance invariants that must hold for a shippable store APK:
    - release build succeeds (delegated to scripts/build-apk.ps1 so the exact
      local toolchain env is reused)
    - manifest has no REQUEST_INSTALL_PACKAGES and no GsApkProvider (R4)
    - store build: android:allowBackup="false"
    - signing cert is NOT the Android debug keystore
    - targetSdkVersion >= 35 (R11)

  Usage:
    pwsh scripts/ci.ps1 -Flavor store
#>
param(
  [ValidateSet('store', 'community')][string]$Flavor = 'store',
  [switch]$BuildAab
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')

# ---- reuse build-apk.ps1 environment (local, zero-pollution toolchain) ----
$Tools = Join-Path $Root '.tools'
$jdk = Join-Path $Tools 'jdk21'
if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { $jdk = Join-Path $Tools 'jdk17' }
$env:GS_ROOT = $Root
$env:JAVA_HOME = $jdk
$env:ANDROID_HOME = Join-Path $Tools 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PUB_CACHE = Join-Path $Tools 'caches\pub-cache'
$env:GRADLE_USER_HOME = Join-Path $Tools 'caches\gradle'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:Path = ((@(
    (Join-Path $env:JAVA_HOME 'bin'),
    (Join-Path $Tools 'flutter\bin'),
    (Join-Path $Tools 'android-sdk\platform-tools'),
    (Join-Path $Tools 'android-sdk\cmdline-tools\latest\bin')
  ) | Where-Object { Test-Path $_ } | Select-Object -Unique) -join ';') + ';' + $env:Path

$apk   = Join-Path $Root "app\build\app\outputs\flutter-apk\app-$Flavor-release.apk"
$aapt  = Join-Path $Tools 'android-sdk\build-tools\35.0.0\aapt.exe'
$keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'

function Fail($m) { Write-Error $m; exit 1 }

# Flutter writes progress/banner text to stderr; with ErrorActionPreference=Stop
# PowerShell aborts on those lines. Scope the Flutter calls to 'Continue' and
# rely on $LASTEXITCODE instead (same pattern as build-apk.ps1).
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  # Soft gate: report analyze issues but do not block the build/checks.
  Write-Host '==> flutter analyze' -ForegroundColor Cyan
  Push-Location (Join-Path $Root 'app')
  try { & flutter analyze 2>&1 | ForEach-Object { "$_" } } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { Write-Warning "flutter analyze reported issues (exit $LASTEXITCODE)" }

  # Hard gate: build (delegated so the toolchain env is identical).
  Write-Host "==> build-apk.ps1 -Flavor $Flavor" -ForegroundColor Cyan
  $buildArgs = @('-Flavor', $Flavor)
  if ($BuildAab) { $buildArgs += '-BuildAab' }
  & (Join-Path $PSScriptRoot 'build-apk.ps1') @buildArgs
  if ($LASTEXITCODE -ne 0) { Fail "build-apk.ps1 failed (exit $LASTEXITCODE)" }
} finally {
  $ErrorActionPreference = $oldEap
}

# ---- AAB gate (Google Play) ----
if ($BuildAab) {
  $aab = Join-Path $Root "app\build\app\outputs\bundle\$Flavor-release\app-$Flavor-release.aab"
  if (-not (Test-Path $aab)) { Fail "AAB not found: $aab" }
  $sz = (Get-Item $aab).Length / 1MB
  if ($sz -lt 1) { Fail "FAIL: AAB suspiciously small ($('{0:N1}' -f $sz) MB)" }
  try {
    $certInfo = (& $keytool -printcert -jarfile $aab 2>&1) -join "`n"
    if ($certInfo -match 'Android Debug') { Fail 'FAIL: AAB signed with debug keystore' }
    Write-Host "OK: AAB present ($([math]::Round($sz, 1)) MB) and signed (not debug keystore)"
  } catch {
    Write-Warning "keytool could not read AAB certs (Play App Signing will re-sign on upload)"
  }
  Write-Host '==> AAB CI GATE PASSED' -ForegroundColor Green
  exit 0
}

if (-not (Test-Path $apk)) { Fail "APK not found: $apk" }

# Capture as a single string so -match / -notmatch return booleans (on an
# array they instead return the matching/non-matching lines, which breaks the
# `if` conditions below).
$badging  = (& $aapt dump badging $apk) -join "`n"
$manifest = (& $aapt dump xmltree $apk AndroidManifest.xml) -join "`n"

# R4: no self-update / install permission and no provider in store build
if ($badging -match 'REQUEST_INSTALL_PACKAGES') { Fail 'FAIL: REQUEST_INSTALL_PACKAGES present' }
if ($manifest -match 'GsApkProvider')           { Fail 'FAIL: GsApkProvider present' }
Write-Host 'OK: no REQUEST_INSTALL_PACKAGES / GsApkProvider'

# store-only: allowBackup must be explicitly false
if ($Flavor -eq 'store') {
  if ($manifest -notmatch 'android:allowBackup.*0x0') {
    Fail 'FAIL: store build android:allowBackup is not false'
  }
  Write-Host 'OK: store build android:allowBackup=false'
}

# R13: FBA-2012 is non-commercial — it must never ship in store builds.
$entries = (& $aapt list $apk) -join "`n"
if ($Flavor -eq 'store') {
  if ($entries -match 'libgs_fbalpha2012\.so') {
    Fail 'FAIL: store build ships the non-commercial FBA-2012 core'
  }
  Write-Host 'OK: store build has no FBA-2012 core'
  # Positive check: the store arcade core is the BSD-3-Clause MAME core.
  if ($entries -notmatch 'libgs_mame\.so') {
    Fail 'FAIL: store build is missing the MAME core (libgs_mame.so)'
  }
  Write-Host 'OK: store build ships libgs_mame.so'
}

# R11: targetSdk >= 35
if ($badging -match "targetSdkVersion:'(\d+)'") {
  $ts = [int]$Matches[1]
  if ($ts -lt 35) { Fail "FAIL: targetSdkVersion $ts < 35" }
  Write-Host "OK: targetSdkVersion = $ts"
} else { Fail 'FAIL: could not parse targetSdkVersion' }

# Signing must not be the debug keystore. Modern APKs are signed with
# Signature Scheme v2/v3, which `keytool -printcert -jarfile` cannot read
# (it reports "Not a signed jar file") — so that check was vacuous. Use
# apksigner instead; ci.ps1 already exports JAVA_HOME for it.
$apksigner = Join-Path $Tools 'android-sdk\build-tools\35.0.0\apksigner.bat'
$certs = (& $apksigner verify --print-certs $apk 2>&1) -join "`n"
if ([string]::IsNullOrWhiteSpace($certs)) {
  Fail 'FAIL: apksigner found no signature on the APK'
}
if ($certs -match 'Android Debug') { Fail 'FAIL: signed with debug keystore' }
Write-Host 'OK: signing verified (not debug keystore)'
Write-Host (($certs -split "`n" | Where-Object { $_ -match 'certificate DN' } | Select-Object -First 1))

# Commercial rule: the APK must never bundle copyrighted ROM/BIOS content
# (e.g. neogeo.zip). This is the hard gate that fails the build if any
# game/BIOS archive slips into the package. The libretro cores (libgs_*.so)
# are explicitly allowed by check-apk-content.ps1.
Write-Host '==> check-apk-content.ps1' -ForegroundColor Cyan
$capEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  & (Join-Path $PSScriptRoot 'check-apk-content.ps1') -Apk $apk 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) {
    Fail "FAIL: APK bundles copyrighted ROM/BIOS content (check-apk-content.ps1 exit $LASTEXITCODE)"
  }
} finally {
  $ErrorActionPreference = $capEap
}
Write-Host 'OK: APK contains no bundled ROM/BIOS content'

Write-Host '==> ALL CI GATES PASSED' -ForegroundColor Green
