# Build the OpenHarmony / HarmonyOS NEXT HAP for GamePouch.
#
# Prerequisites (see docs/ohos7-feasibility.md P0/P1):
#   - flutter_ohos switched to the OpenHarmony fork (P0 done: 3.41.10-ohos / Dart 3.11.5)
#   - app/ohos/ scaffold exists (P1 done via `flutter create --platforms ohos .`)
#   - OHOS SDK reachable via OHOS_SDK_HOME / OHOS_HOME (set by use-env.ps1 -Ohos)
#   - A signing config for the device. The scaffold ships `signingConfigs: []`;
#     for a real device you must either let DevEco auto-sign (debug) or supply a
#     material/debug cert (P2). Pass -NoCodesign to stage an unsigned HAP.
#
# Usage:
#   .\scripts\build-hap.ps1                # debug HAP (arm64), auto-codesign
#   .\scripts\build-hap.ps1 -Release       # release HAP
#   .\scripts\build-hap.ps1 -NoCodesign    # skip codesign (cannot deploy, used to test compile)
param(
  [switch]$Release,
  [switch]$NoCodesign,
  # Extra `--dart-define=K=V` values, comma-separated. Used by the on-device
  # wiring probe (GP_OHOS_SELFTEST / GP_PROBE_ROM / GP_PROBE_CORE / ...).
  [string]$DartDefine = ''
)

$ErrorActionPreference = 'Stop'
$Root  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppDir = Join-Path $Root 'app'

# Isolate the OHOS toolchain (flutter_ohos + OHOS SDK + separate PUB_CACHE).
# -HarmonyOS points the SDK env vars at the HarmonyOS 26 SDK (with hms) so the
# emitted HAP targets HarmonyOS NEXT (required for AppGallery). OpenHarmony-only
# builds are no longer the default target for this project.
. (Join-Path $PSScriptRoot 'use-env.ps1') -Ohos -HarmonyOS

$buildMode = if ($Release) { 'release' } else { 'debug' }
$codesign  = if ($NoCodesign) { '--no-codesign' } else { '' }

$dartDefines = @()
if ($DartDefine) {
  foreach ($d in ($DartDefine -split ',')) {
    $t = $d.Trim()
    if ($t) { $dartDefines += "--dart-define=$t" }
  }
}

Write-Host "[build-hap] mode=$buildMode  flutter=$(flutter --version 2>$null | Select-Object -First 1)"

Push-Location $AppDir
try {
  # `flutter build hap` is the OpenHarmony fork's HAP target.
  # target-platform defaults to ohos-arm64 (device is arm64-v8a / API 26).
  flutter build hap --$buildMode $codesign $dartDefines
  $exit = $LASTEXITCODE
  if ($exit -eq 0) {
    Write-Host "[build-hap] OK -> app/build/ohos/$buildMode/  (entry-default-signed.hap)"
  } else {
    Write-Warning "[build-hap] flutter build hap exited $exit"
  }
  exit $exit
} finally {
  Pop-Location
}
