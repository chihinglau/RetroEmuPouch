# 按 skills.md §2.6 / §1377 构建 Pura70 真机探针 HAP。
#
# - 默认：街机 BIOS A/B 探针（GP_BIOS_PROBE=true）。场景由主机推送
#   /data/local/tmp/gp_bios_probe.json 控制，一次构建可跑多轮 A/B，
#   报告写在 <filesDir>/bios_probe.txt（app/lib/probe/arcade_bios_probe.dart）。
# - -WiringSelfTest：旧的设置页链路自测（GP_OHOS_SELFTEST=true），
#   目标 ROM / 核心用 -Rom -Core -Platform 覆盖，报告在 selftest.txt。
param(
  [switch]$WiringSelfTest,
  [string]$Cmd = '',
  [string]$Rom = 'roms/peer/dino.zip',
  [string]$Core = 'mame',
  [string]$Platform = 'mame'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# GP_BIOS_CMD uses ';' as the field separator: build-hap.ps1 splits
# -DartDefine on commas (so no comma in a value), and flutter.bat is launched
# through cmd.exe (so '|' / '&' would be interpreted as command operators).
$defines = if ($WiringSelfTest) {
  "GP_OHOS_SELFTEST=true,GP_PROBE_ROM=$Rom,GP_PROBE_CORE=$Core,GP_PROBE_PLATFORM=$Platform"
} elseif ($Cmd) {
  "GP_BIOS_PROBE=true,GP_BIOS_CMD=$Cmd"
} else {
  'GP_BIOS_PROBE=true'
}

Write-Host "[probe-build] DartDefine=$defines"
& "$root\scripts\build-hap.ps1" -DartDefine $defines
$hap = "$root\app\build\ohos\hap\entry-default-signed.hap"
if ($LASTEXITCODE -eq 0) {
  Write-Host "[probe-build] OK -> $hap"
} else {
  throw "[probe-build] build-hap.ps1 failed with exit=$LASTEXITCODE"
}
