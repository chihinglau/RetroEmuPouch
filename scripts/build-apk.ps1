#requires -Version 5.1
<#
  Build the GamePouch Android APK with the local (zero-pollution) toolchain.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store -SplitPerAbi
    powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -DebugBuild

  -Flavor   store | community   (default community; see remediation P0-1b)
            Must match the --dart-define CHANNEL passed to Flutter.
  -BuildAab                  Build an Android App Bundle (.aab) for Google Play
                            instead of a single APK (Play only accepts AAB).
                            For Play, enroll in Play App Signing and use a
                            dedicated upload key (scripts/new-upload-key.ps1),
                            NOT the app's release keystore.
  Output:
    app\build\app\outputs\flutter-apk\app-<flavor>-release.apk   (or -debug)
    app\build\app\outputs\bundle\<flavor>-release\app-<flavor>-release.aab  (-BuildAab)
#>
[CmdletBinding()]
param(
  [ValidateSet('store', 'community')]
  [string]$Flavor = 'community',
  [switch]$DebugBuild,
  [switch]$SplitPerAbi,
  [switch]$BuildAab,
  [switch]$NoPubGet
)
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path }

# ---- environment (same values as scripts\use-env.ps1) ----
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

$flutter = Join-Path $Tools 'flutter\bin\flutter.bat'
$app = Join-Path $Root 'app'

Write-Host "[env] JAVA_HOME=$env:JAVA_HOME" -ForegroundColor Cyan
Write-Host "[env] ANDROID_HOME=$env:ANDROID_HOME" -ForegroundColor Cyan

Push-Location $app
# flutter.bat writes progress/banner text to stderr; with ErrorActionPreference=Stop
# PowerShell would abort the script on those lines. Keep 'Continue' here and rely
# on $LASTEXITCODE instead.
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  if (-not $NoPubGet) {
    Write-Host "`n========== flutter pub get ==========" -ForegroundColor Cyan
    & $flutter pub get 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
  }

  if ($BuildAab) {
    # Google Play only accepts AAB. The bundle includes all ABIs by design,
    # so do NOT pass --target-platform (unlike the APK build, which is
    # arm64-only). Signing uses the same Gradle release config; for Play,
    # enroll in Play App Signing and upload a *dedicated* upload key
    # (scripts/new-upload-key.ps1) — never the app's release keystore.
    $args = @('build', 'appbundle')
    if ($DebugBuild) { $args += '--debug' } else { $args += '--release' }
    $args += '--flavor', $Flavor
    $args += '--dart-define', "CHANNEL=$Flavor"
    $artifactPattern = 'Built build\\app\\outputs\\bundle'
    $outDir = Join-Path $app "build\app\outputs\bundle\$Flavor-release"
    $artifactFilter = '*.aab'
  } else {
    $args = @('build', 'apk', '--target-platform', 'android-arm64')
    if ($DebugBuild) { $args += '--debug' } else { $args += '--release' }
    $args += '--flavor', $Flavor
    $args += '--dart-define', "CHANNEL=$Flavor"
    if ($SplitPerAbi) { $args += '--split-per-abi' }
    $artifactPattern = 'Built build\\.*\.apk'
    $outDir = Join-Path $app 'build\app\outputs\flutter-apk'
    $artifactFilter = '*.apk'
  }

  Write-Host "`n========== flutter $($args -join ' ') ==========" -ForegroundColor Cyan
  $log = Join-Path $Root 'build-apk.log'
  $errLog = Join-Path $Root 'build-apk.err'
  # Redirect flutter's output to files instead of piping it through PowerShell.
  # A `flutter ... 2>&1 | Tee-Object` pipeline can hang forever after the build
  # has already finished: the release Gradle daemon inherits the stdout pipe and
  # keeps it open, so PowerShell never sees EOF and the script "won't quit" even
  # though the APK is built. Polling the *process* (flutter returns the moment
  # Gradle reports success) plus an explicit "Built ...apk" check is how we know
  # the release build succeeded and can exit cleanly.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $buildProc = Start-Process -FilePath $flutter -ArgumentList $args `
    -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $errLog
  $timeoutMin = 40
  while (-not $buildProc.HasExited -and $sw.Elapsed.TotalMinutes -lt $timeoutMin) {
    Start-Sleep -Seconds 3
  }
  if (-not $buildProc.HasExited) {
    Write-Host "build exceeded ${timeoutMin}min — killing build process" -ForegroundColor Yellow
    $buildProc.Kill()
  }
  Start-Sleep -Seconds 2   # let the redirect flush the tail of the log
  # Stop lingering Gradle daemons (release daemon can hold ports / file handles).
  $gradlew = Join-Path $Root 'app\android\gradlew.bat'
  if (Test-Path -LiteralPath $gradlew) { & $gradlew --stop 2>&1 | Out-Null }
  # flutter writes its banner/progress to stderr; merge it into the log so the
  # whole build transcript lives in build-apk.log.
  if (Test-Path -LiteralPath $errLog) {
    Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue |
      ForEach-Object { Add-Content -LiteralPath $log -Value $_ }
  }
  $exitCode = if ($buildProc.HasExited) { $buildProc.ExitCode } else { -1 }
  $built = Select-String -LiteralPath $log -Pattern $artifactPattern -ErrorAction SilentlyContinue
  if ($exitCode -ne 0 -and -not $built) {
    Write-Host "`n========== build failed (exit=$exitCode) — last 30 log lines ==========" -ForegroundColor Red
    Get-Content -LiteralPath $log -Tail 30 -ErrorAction SilentlyContinue | Write-Host
    throw "flutter build apk failed (exit=$exitCode); see $log"
  }

  Write-Host ("`n========== build OK in {0:N0}s ==========" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
  "========== artifacts ==========" | Tee-Object -FilePath $log -Append
  Get-ChildItem -LiteralPath $outDir -Filter $artifactFilter -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { '{0}  {1:N1} MB' -f $_.FullName, ($_.Length / 1MB) } |
    Tee-Object -FilePath $log -Append
}
finally {
  $ErrorActionPreference = $oldEap
  Pop-Location
}
