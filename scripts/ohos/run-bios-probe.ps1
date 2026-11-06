# 按 skills.md §2.6 / §3 / §1377 在 Pura70 上跑一轮街机 BIOS A/B 探针。
#
# hdc 既不能写应用沙盒，Flutter 进程也读不到 /data/local/tmp（SELinux），
# 所以每个场景都在构建时通过 GP_BIOS_CMD 编进 HAP —— 本脚本按顺序执行
# 「生成场景参数 → 构建签名 HAP → hdc install -r → 冷启动 → 读报告」。
#
#   python scripts\ohos\prepare-bios-probe.py
#   .\scripts\ohos\run-bios-probe.ps1 -Scenario A-baseline
#   .\scripts\ohos\run-bios-probe.ps1 -Scenario B-no-qsound
#   ...
#   .\scripts\ohos\run-bios-probe.ps1 -Scenario F-restore
param(
  [Parameter(Mandatory = $true)][string]$Scenario,
  [int]$WaitMs = 22000,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $root 'build\bios_probe'
$hdc = 'D:\HuaWei\Sdk\26.0.0\toolchains\hdc.exe'
if (-not (Test-Path $hdc)) {
  $hdc = Join-Path $env:OHOS_BASE_SDK_HOME '12\toolchains\hdc.exe'
}
$pkg = 'com.retroemupouch.app'
$files = '/data/app/el2/100/base/com.retroemupouch.app/files'
$hap = Join-Path $root 'app\build\ohos\hap\entry-default-signed.hap'

$cfg = Join-Path $out "scenarios\$Scenario.json"
if (-not (Test-Path $cfg)) { throw "missing scenario: $cfg" }
$j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json

# ';' separates fields: build-hap.ps1 splits -DartDefine on commas and
# flutter.bat runs through cmd.exe, where '|' / '&' are command operators.
$parts = @(
  "tag=$($j.tag)",
  "rom=$($j.rom)",
  "core=$($j.core)",
  "platform=$($j.platform)",
  "settleMs=$($j.settleMs)"
)
if ($j.restore) { $parts += 'restore=1' }
if ($j.dropHleOnly) { $parts += 'dropHle=1' }
elseif (@($j.drop).Count -gt 0) { $parts += 'drop=1' }
if (@($j.copy).Count -gt 0) {
  $parts += "copyFrom=$($j.copy[0].from)"
  $parts += "copyTo=$($j.copy[0].to)"
  $zip = Join-Path $out 'neogeo_privabios.zip'
  if (Test-Path $zip) {
    & $hdc file send $zip '/data/local/tmp/neogeo_privabios.zip' | Out-Null
  }
}
$cmd = $parts -join ';'
Write-Host "[bios-probe] scenario=$Scenario cmd=$cmd"

if (-not $SkipBuild) {
  & "$root\scripts\ohos\build-probe-hap.ps1" -Cmd $cmd
  & $hdc shell aa force-stop $pkg | Out-Null
  & $hdc install -r $hap
}

Write-Host "[bios-probe] cold start"
& $hdc shell aa force-stop $pkg | Out-Null
Start-Sleep -Milliseconds 800
& $hdc shell aa start -a EntryAbility -b $pkg | Out-Null

Write-Host "[bios-probe] waiting ${WaitMs}ms"
Start-Sleep -Milliseconds $WaitMs

$report = & $hdc shell -b $pkg cat "$files/bios_probe.txt"
$dest = Join-Path $out "results\$Scenario.txt"
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
[System.IO.File]::WriteAllText($dest, ($report -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "[bios-probe] report -> $dest"
$report | Select-String -Pattern 'tag=|launch.ok|getLoadError|isCoreReady|getFps|result.booted|EXCEPTION|tmp.json|pre system/qsound.zip|post system/qsound.zip' | ForEach-Object { $_.Line }
