<#
.SYNOPSIS
  Real-device PrivaBIOS compatibility check on the Android OXF test device
  (66B0219C18003002), following the skills.md §4 / §6 adb + run-as + bench chain.

  Replaces sp-s2.sp1 (MAME BIOS index 0) inside the device's user-supplied
  neogeo.zip with the GPL-3.0 PrivaBIOS, boots one NeoGeo game through
  EmulatorActivity's benchmark entry, and restores the original BIOS.

  COMPLIANCE: the test zip lives under build/ (gitignored), contains the
  user's own local BIOS bundle and is pushed ONLY to a test device's private
  files dir. It is never committed, never packaged into an APK/HAP, and never
  used in soft-copyright material.

.PARAMETER Rom
  ROM path relative to the app filesDir (default roms/peer/kof97.zip).
.PARAMETER BenchSeconds
  Seconds of emulation the bench should run (skills.md §6 uses 3).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\mame\verify-privabios.ps1
#>
param(
  [string]$Rom = 'roms/peer/kof97.zip',
  [int]$BenchSeconds = 3,
  [switch]$UseOriginalBios
)

# 'Continue': adb writes progress to stderr, which under 'Stop' becomes a
# terminating NativeCommandError even on success (skills.md §6 / refresh-roms).
$ErrorActionPreference = 'Continue'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d = '66B0219C18003002'
$pkg = 'com.retroemupouch.app'
$testZip = "$root\build\bios_probe\neogeo_privabios.zip"
$resultDir = "$root\build\bios_probe\results"
$tag = if ($UseOriginalBios) { 'baseline-android' } else { 'priva-android' }
$report = "$resultDir\$tag.txt"
$log = "$root\build\bios_probe\$tag-logcat.txt"
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

if (-not (Test-Path $testZip)) { throw "missing $testZip (run scripts\ohos\prepare-bios-probe.py)" }
$devs = (& $adb devices) -join "`n"
if ($devs -notmatch [regex]::Escape($d)) { throw 'OXF device offline' }

function A([string]$cmd) { & $adb -s $d shell $cmd 2>&1 }
$lines = @()
function Rec([string]$s) { $script:lines += $s; Write-Host $s }

$ra = "run-as $pkg"
$biosPaths = @(
  'files/system/neogeo.zip',
  'files/system/mame/roms/neogeo.zip',
  'files/rom_cache/mame/neogeo.zip'
)

Rec "device=$d rom=$Rom benchSeconds=$BenchSeconds mode=$tag"
Rec "testZip=$(Get-FileHash $testZip -Algorithm SHA256 | Select-Object -ExpandProperty Hash)"

if (-not $UseOriginalBios) {
# 1) Back up the original BIOS copies (once) so the device can be restored.
foreach ($p in $biosPaths) {
  $exists = (A "$ra sh -c 'test -f $p && echo YES || echo NO'") -join ''
  if ($exists -match 'YES') {
    A "$ra sh -c 'test -f $p.gpbak || cp $p $p.gpbak'" | Out-Null
    Rec "backup $p"
  } else {
    Rec "absent  $p"
  }
}

# 2) Stage the PrivaBIOS bundle into every MAME rompath entry.
& $adb -s $d push $testZip '/data/local/tmp/neogeo_privabios.zip' 2>&1 | Out-Null
A "$ra sh -c 'mkdir -p /data/data/$pkg/files/system/mame/roms /data/data/$pkg/files/rom_cache/mame'" | Out-Null
foreach ($p in $biosPaths) {
  A "$ra sh -c 'cp /data/local/tmp/neogeo_privabios.zip /data/data/$pkg/$p && echo OK_$p'" | Out-Null
  Rec "deploy $p"
}
$deployed = (A "$ra sh -c 'ls -l /data/data/$pkg/files/system/neogeo.zip'") -join ''
Rec "deployed=$deployed"
}

# 3) Bench-boot one NeoGeo game (skills.md §6 verification pattern).
& $adb -s $d shell am force-stop $pkg 2>&1 | Out-Null
& $adb -s $d logcat -c 2>&1 | Out-Null
& $adb -s $d shell am start -n "$pkg/.EmulatorActivity" `
  --es bench_rom $Rom --es bench_core mame `
  --ei bench_seconds $BenchSeconds --es bench_id privabios_kof97 2>&1 | Out-Null

$status = 'TIMEOUT'
$reason = ''
for ($i = 0; $i -lt 10; $i++) {
  Start-Sleep -Seconds 2
  $lg = & $adb -s $d logcat -d -v brief 2>$null
  $hit = $lg | Select-String -Pattern 'GS-runner.*\[pace\]|GS-CORE-FAIL'
  if ($hit) {
    $line = ($hit | Select-Object -Last 1).ToString()
    if ($line -match 'GS-CORE-FAIL') {
      $status = 'FAIL'
      $reason = ($line -replace '.*GS-CORE-FAIL ', '')
    } else {
      $status = 'PASS'
      $reason = $line
    }
    break
  }
}
[System.IO.File]::WriteAllText($log, ((& $adb -s $d logcat -d -v brief 2>$null) -join "`n"), (New-Object System.Text.UTF8Encoding $false))
$checksum = (Get-Content $log | Select-String -Pattern 'WRONG CHECKSUMS|WRONG LENGTH|sp-s2|Priva|NOT FOUND' | Select-Object -First 8) -join ' | '
Rec "status=$status reason=$reason"
Rec "coreLogHints=$checksum"

# 4) Restore the original BIOS on the test device.
& $adb -s $d shell am force-stop $pkg 2>&1 | Out-Null
if (-not $UseOriginalBios) {
  foreach ($p in $biosPaths) {
    A "$ra sh -c 'test -f $p.gpbak && cp $p.gpbak $p'" | Out-Null
  }
  Rec 'restore.done=true'
}
Rec "report=$report"
[System.IO.File]::WriteAllText($report, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
