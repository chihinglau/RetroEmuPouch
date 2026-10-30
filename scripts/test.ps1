<#
  Runs the GamePouch unit / widget test suite.

  WHY A WRAPPER:
    `appChannel` is a compile-time const that defaults to the STORE channel
    (see app/lib/config/app_channel.dart). A bare `flutter test` therefore
    runs under the store channel, where:
      - arcade cores resolve via the `mame` id (store ships libgs_mame.so),
        not `fbalpha2012`;
      - peer / cloud ROM distribution is forbidden (canCloudRom = false).
    The test suite is written against COMMUNITY-channel semantics (FBA-2012
    id, ROM downloads allowed), so 5 channel-dependent tests fail under a
    bare `flutter test`. Default to community here to keep the suite green.

  USAGE:
    pwsh scripts/test.ps1                       # all tests, community channel
    pwsh scripts/test.ps1 -Channel store        # store channel
    pwsh scripts/test.ps1 test/foo_test.dart    # single file (extra args pass through)
#>
param(
  [ValidateSet('store', 'community')][string]$Channel = 'community',
  [Parameter(ValueFromRemainingArguments)]$ExtraArgs
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')

# Reuse the local, zero-pollution toolchain env (same as use-env.ps1 / ci.ps1).
$Tools = Join-Path $Root '.tools'
$jdk = Join-Path $Tools 'jdk21'
if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { $jdk = Join-Path $Tools 'jdk17' }
$env:GS_ROOT             = $Root
$env:JAVA_HOME           = $jdk
$env:ANDROID_HOME        = Join-Path $Tools 'android-sdk'
$env:ANDROID_SDK_ROOT    = $env:ANDROID_HOME
$env:PUB_CACHE           = Join-Path $Tools 'caches\pub-cache'
$env:GRADLE_USER_HOME    = Join-Path $Tools 'caches\gradle'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL      = 'https://pub.flutter-io.cn'
$env:Path = ((@(
    (Join-Path $env:JAVA_HOME 'bin'),
    (Join-Path $Tools 'flutter\bin'),
    (Join-Path $Tools 'android-sdk\platform-tools'),
    (Join-Path $Tools 'android-sdk\cmdline-tools\latest\bin')
  ) | Where-Object { Test-Path $_ } | Select-Object -Unique) -join ';') + ';' + $env:Path

# Flutter writes progress/banner text to stderr; under ErrorActionPreference
# = Stop PowerShell aborts on those lines. Scope the call to 'Continue' and
# rely on $LASTEXITCODE instead (same pattern as ci.ps1).
Push-Location (Join-Path $Root 'app')
try {
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & flutter test --dart-define "CHANNEL=$Channel" @ExtraArgs
  } finally {
    $ErrorActionPreference = $oldEap
  }
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
