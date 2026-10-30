<#
.SYNOPSIS
  One-stop refresh for GamePouch arcade testing on the OXF device (66B0219C18003002):
    1) centralize BIOS blobs (neogeo.zip + qsound.zip) into .tools/gstest/bios
    2) replace ROMs in the given device folders with complete dumps from a
       MAME 0.289 split set (default G:\software\game\mame\...\(split))
    3) deploy BIOS to the MAME rompath (system/mame/roms + system/neogeo.zip)
    4) (optional) verify each ROM boots under the libretro MAME core

  COMPLIANCE: BIOS stays under .tools/gstest/bios which is git-ignored (/.tools/)
  and is NEVER packaged into the APK. The commercial no-ROM/BIOS rule is enforced
  by scripts/ci.ps1 (check-apk-content.ps1). This script only stages BIOS onto a
  TEST device's private filesystem.

.PARAMETER Dirs
  Device ROM folders to refresh (default all arcade: NeoGeo, Cps1, Cps2).

.PARAMETER SplitSet / BiosSet
  Source ROM library directories on the G: drive.

.PARAMETER NoRefreshBios / NoRefreshRoms / SkipVerify
  Skip a stage. Verification is ON by default; pass -SkipVerify to only deploy.

.EXAMPLE
  # Full: centralize BIOS + replace all arcade ROMs + deploy + verify (~15 min)
  powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1

  # Fast deploy only (reuse already-staged local ROMs/BIOS), no verify
  powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1 -NoRefreshBios -NoRefreshRoms -SkipVerify

  # Only NeoGeo, skip verify
  powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1 -Dirs NeoGeo -SkipVerify
#>
param(
  [string[]]$Dirs = @('NeoGeo', 'Cps1', 'Cps2'),
  [string]$SplitSet = 'G:\software\game\mame\MAME 0.289 ROMs (split)',
  [string]$BiosSet  = 'G:\software\game\mame\MAME 0.289 ROMs (bios-devices)',
  [switch]$NoRefreshBios,
  [switch]$NoRefreshRoms,
  [switch]$SkipVerify,
  [int]$BenchSeconds = 3
)

# 'Continue' (not 'Stop'): native adb writes progress to stderr, which under Stop
# becomes a terminating NativeCommandError even on success. Gate on $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$root      = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb       = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d         = '66B0219C18003002'
$biosDir   = "$root\.tools\gstest\bios"
$localBase = "$root\.tools\gstest\roms"
$log       = "$root\build\refresh-roms.log"
function Log($m){ $m | Out-File -Append -FilePath $log -Encoding utf8 }
Log "=== refresh-roms start $(Get-Date)  Dirs=$($Dirs -join ',') ==="

# ---- 0) device online (join first: -notmatch on a string array is truthy) ----
$devs = (& $adb devices) -join "`n"
if ($devs -notmatch [regex]::Escape($d)) { Log 'ABORT: device offline'; Write-Host 'ABORT: device offline' -ForegroundColor Red; exit 1 }
Log 'device online'

# ---- 1) centralize BIOS blobs into .tools/gstest/bios ----
if (-not $NoRefreshBios) {
  Log '--- stage 1: centralize BIOS ---'
  New-Item -ItemType Directory -Force -Path $biosDir | Out-Null
  foreach ($f in 'neogeo.zip', 'qsound.zip') {
    $src = Join-Path $BiosSet $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $biosDir $f) -Force; Log ("bios copied: $f") }
    else { Log ("bios MISSING in BiosSet: $f") }
  }
} else { Log '--- stage 1 skipped (NoRefreshBios) ---' }

# ---- 2) replace ROMs from the split set ----
if (-not $NoRefreshRoms) {
  Log '--- stage 2: replace ROMs from split set ---'
  foreach ($dir in $Dirs) {
    $roms = & $adb -s $d shell "run-as com.retroemupouch.app ls files/roms/$dir" 2>$null |
      Where-Object { $_ -match '\.zip$' } | ForEach-Object { $_.Trim() }
    if (-not $roms) { Log ("$dir : no roms on device"); continue }
    $localDir = "$localBase\$dir"
    New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    $found = 0
    foreach ($r in $roms) {
      $src = Join-Path $SplitSet $r
      if (Test-Path $src) { Copy-Item $src (Join-Path $localDir $r) -Force; $found++ }
    }
    Log ("$dir : staged $found / " + $roms.Count + " from split set")
    & $adb -s $d push $localDir "/data/local/tmp/refresh_$dir" *>> $log 2>&1
    Log ("$dir push exit=$LASTEXITCODE")
    & $adb -s $d shell "run-as com.retroemupouch.app sh -c 'cp /data/local/tmp/refresh_$dir/*.zip /data/data/com.retroemupouch.app/files/roms/$dir/ && echo ${dir}_OK'" *>> $log 2>&1
    Log ("$dir cp exit=$LASTEXITCODE")
  }
} else { Log '--- stage 2 skipped (NoRefreshRoms) ---' }

# ---- 3) deploy BIOS to the MAME rompath ----
Log '--- stage 3: deploy BIOS ---'
& $adb -s $d push "$biosDir\neogeo.zip" /data/local/tmp/neogeo_bios.zip *>> $log 2>&1
& $adb -s $d push "$biosDir\qsound.zip" /data/local/tmp/qsound.zip *>> $log 2>&1
& $adb -s $d shell "run-as com.retroemupouch.app sh -c 'mkdir -p /data/data/com.retroemupouch.app/files/system/mame/roms && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/mame/roms/neogeo.zip && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/neogeo.zip && cp /data/local/tmp/qsound.zip /data/data/com.retroemupouch.app/files/system/mame/roms/qsound.zip && echo BIOS_OK'" *>> $log 2>&1
Log ("deploy bios exit=$LASTEXITCODE")

# ---- 4) verify (optional) ----
if (-not $SkipVerify) {
  Log '--- stage 4: verify ---'
  foreach ($dir in $Dirs) {
    $out = "$root\build\verify_$dir.csv"
    [System.IO.File]::WriteAllText($out, "rom,status,reason`n", (New-Object System.Text.UTF8Encoding $false))
    $roms = & $adb -s $d shell "run-as com.retroemupouch.app ls files/roms/$dir" 2>$null |
      Where-Object { $_ -match '\.zip$' -and $_ -notmatch '^neogeo\.zip$' } | ForEach-Object { $_.Trim() }
    $pass = 0; $fail = 0; $total = 0
    foreach ($r in $roms) {
      & $adb -s $d logcat -c | Out-Null
      & $adb -s $d shell am start -n com.retroemupouch.app/.EmulatorActivity `
        --es bench_rom "roms/$dir/$r" --es bench_core mame `
        --ei bench_seconds $BenchSeconds --es bench_id "v_$r" 2>&1 | Out-Null
      $status = 'TIMEOUT'; $reason = ''
      for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Seconds 2
        $lg = & $adb -s $d logcat -d -v brief 2>$null | Select-String -Pattern 'GS-runner.*\[pace\]|GS-CORE-FAIL'
        if ($lg) {
          $line = ($lg | Select-Object -Last 1).ToString()
          if ($line -match 'GS-CORE-FAIL') { $status = 'FAIL'; $reason = ($line -replace '.*GS-CORE-FAIL ','').Replace(',',';') }
          else { $status = 'PASS' }
          break
        }
      }
      if ($status -eq 'TIMEOUT') { $reason = 'no-frames/timeout' }
      if ($status -eq 'PASS') { $pass++ } else { $fail++ }
      $total++
      [System.IO.File]::AppendAllText($out, ('{0},{1},{2}' -f $r, $status, $reason) + "`n", (New-Object System.Text.UTF8Encoding $false))
      & $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
      Write-Host "$dir/$r -> $status"
    }
    Log ("$dir : TOTAL=$total PASS=$pass FAIL=$fail")
    Write-Host "$dir : TOTAL=$total PASS=$pass FAIL=$fail"
  }
} else { Log '--- stage 4 skipped (SkipVerify) ---' }

Log "=== refresh-roms done $(Get-Date) ==="
Write-Host "refresh-roms done (see build/refresh-roms.log)" -ForegroundColor Green
