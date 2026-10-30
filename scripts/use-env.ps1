# Session-level environment injection (dot-source me, do not run directly).
#   . .\scripts\use-env.ps1
#   . .\scripts\use-env.ps1 -Ohos
param([switch]$Ohos, [switch]$HarmonyOS)

$Root  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
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

$paths = @(
  (Join-Path $env:JAVA_HOME 'bin'),
  (Join-Path $Tools 'flutter\bin'),
  (Join-Path $Tools 'android-sdk\platform-tools'),
  (Join-Path $Tools 'android-sdk\cmdline-tools\latest\bin'),
  (Join-Path $Tools 'android-sdk\cmake\3.22.1\bin'),
  (Join-Path $Tools 'android-sdk\ndk\28.2.13676358')
)

if ($Ohos) {
  $paths = @((Join-Path $Tools 'flutter_ohos\bin')) + $paths
  # OpenHarmony SDK（flutter_ohos 的 OhosSdk 只认 OHOS_SDK_HOME / OHOS_HOME / flutter config ohos-sdk，
  # 不认 DEVECO_SDK_HOME）。D:\HuaWei\Sdk 下 26.0.0 含小数点，工具按数字目录扫描会忽略，
  # 故用中立根目录 + junction（26->26.0.0, 12->12）让 API 26 被识别且 hdc 可定位。
  # 默认 OpenHarmony SDK（无 hms）。传 -HarmonyOS 时切到 DevEco 自带的 HarmonyOS 26
  # SDK（带 hms，apiVersion 26），用于构建可上架 AppGallery 的包。Pura70 两种系统都能跑，
  # 故 OpenHarmony 与 HarmonyOS 两个 product 均可真机验证。
  $ohosToolchain = 'D:\HuaWei\OhosSdkForFlutter\26\toolchains'
  if ($HarmonyOS) {
    $hk       = 'D:\HuaWei\DevEco-Studio\sdk\default'   # HarmonyOS 26 SDK 根（hms/ + openharmony/ + sdk-pkg.json）
    $hkParent = 'D:\HuaWei\DevEco-Studio\sdk'           # hvigor 在此扫描 sdk-pkg.json
    $env:OHOS_SDK_HOME      = $hk
    $env:OHOS_HOME          = $hk
    $env:OHOS_BASE_SDK_HOME = $hk
    $env:DEVECO_SDK_HOME    = $hkParent
    $env:HOS_SDK_HOME       = $hkParent
    $ohosToolchain = Join-Path $hk 'openharmony\toolchains'
  } else {
    $env:OHOS_SDK_HOME = 'D:\HuaWei\OhosSdkForFlutter'
    $env:OHOS_HOME     = 'D:\HuaWei\OhosSdkForFlutter'
    $env:OHOS_BASE_SDK_HOME = 'D:\HuaWei\Sdk'
    $env:DEVECO_SDK_HOME = 'D:\HuaWei\Sdk'
    $env:HOS_SDK_HOME     = 'D:\HuaWei\Sdk'
  }
  foreach ($p in @(
      'D:\HuaWei\DevEco-Studio\tools\node',
      'D:\HuaWei\DevEco-Studio\tools\ohpm\bin',
      'D:\HuaWei\DevEco-Studio\tools\hvigor\bin',
      $ohosToolchain
    )) { if (Test-Path $p) { $paths += $p } else { Write-Warning "missing: $p" } }
  $env:PUB_CACHE = Join-Path $Tools 'caches\pub-cache-official'
}

$env:Path = (($paths | Where-Object { Test-Path $_ } | Select-Object -Unique) -join ';') + ';' + $env:Path

Write-Host "[env] GS_ROOT=$env:GS_ROOT"
Write-Host "[env] JAVA_HOME=$env:JAVA_HOME"
Write-Host "[env] ANDROID_HOME=$env:ANDROID_HOME"
if ($Ohos) { Write-Host '[env] HarmonyOS NEXT toolchain active' } else { Write-Host '[env] Android / Flutter stable active' }
