<#
  Fast NeoGeo verification on the OXF device (66B0219C18003002).

  Unlike rebuild-test.ps1 this SKIPS the multi-hour MAME core rebuild: the
  already-installed libgs_mame.so contains the neogeo/mslug drivers. We only
  need to ship the app-side BIOS-staging fix (LockedRom.kt) and put the BIOS
  where the libretro MAME core searches it, then run the mslug gate.

  Steps:
    1) build store-debug APK (contains the LockedRom.kt fix)  [skippable]
    2) install (-r, signature-preserving)
    3) seed ROMs (device seed.sh) + stage NeoGeo BIOS (system/neogeo.zip +
       system/mame/roms/neogeo.zip)
    4) mslug gate (PASS/FAIL from logcat)

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\mame\test-neogeo.ps1
    powershell -ExecutionPolicy Bypass -File scripts\mame\test-neogeo.ps1 -SkipBuild   # reuse APK
    $env:SEED_BIOS='0'  # skip BIOS staging (CI-style)
#>
param([switch]$SkipBuild)

# 'Continue' (not 'Stop'): native adb writes progress to stderr, which under
# Stop becomes a terminating NativeCommandError even on success. Gate on
# $LASTEXITCODE instead (same pattern as build-mame.ps1 / ci.ps1).
$ErrorActionPreference = 'Continue'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb  = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d    = '66B0219C18003002'
$blog = "$root\build\test-neogeo.log"

# Full MAME 0.289 (or compatible) neogeo.zip; override with $env:NEOGEO_ZIP.
$neogeoZip = if ($env:NEOGEO_ZIP) { $env:NEOGEO_ZIP } else {
    'G:\software\game\mame\MAME 0.289 ROMs (bios-devices)\neogeo.zip'
}
$SeedBios = if ($env:SEED_BIOS) { $env:SEED_BIOS -ne '0' } else { $true }

function Log($m){ $m | Out-File -Append -FilePath $blog -Encoding utf8 }
Log "=== test-neogeo start $(Get-Date) (SkipBuild=$SkipBuild SeedBios=$SeedBios) ==="

# 0) sanity: device online. Join to a single string first — `-notmatch` on a
#    string array returns the non-matching lines (truthy) instead of a boolean.
$devs = (& $adb devices) -join "`n"
if ($devs -notmatch [regex]::Escape($d)) { Log "ABORT: device $d not online"; exit 1 }
Log "device $d online"

$apk = "$root\app\build\app\outputs\flutter-apk\app-store-debug.apk"

# 1) build APK (contains the LockedRom.kt BIOS-staging fix) unless -SkipBuild.
if ($SkipBuild) {
    Log '--- skip build (-SkipBuild); reusing existing APK ---'
} else {
    Log '--- build APK (store debug) ---'
    & powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-apk.ps1" -Flavor store -DebugBuild -NoPubGet *>> $blog 2>&1
    Log "apk exit=$LASTEXITCODE"
}
if (-not (Test-Path $apk)) { Log 'ABORT: APK not built'; exit 1 }
Log "apk ready: $((Get-Item $apk).Length) bytes ($((Get-Item $apk).LastWriteTime))"

# 2) install
Log '--- install ---'
& $adb -s $d install -r $apk *>> $blog 2>&1
Log "install exit=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { Log 'ABORT: install failed'; exit 1 }

# 3) seed ROMs + stage NeoGeo BIOS
Log '--- seed ROMs ---'
& $adb -s $d shell "run-as com.retroemupouch.app sh /data/local/tmp/seed.sh" *>> $blog 2>&1

if ($SeedBios) {
    Log '--- stage NeoGeo BIOS (system/neogeo.zip + system/mame/roms) ---'
    if (Test-Path $neogeoZip) {
        & $adb -s $d push "$neogeoZip" /data/local/tmp/neogeo_bios.zip *>> $blog 2>&1
        Log "push local neogeo.zip exit=$LASTEXITCODE"
    } else {
        Log "WARN: local neogeo.zip not found at '$neogeoZip'; will reuse a device copy if present"
    }
    & $adb -s $d shell "run-as com.retroemupouch.app sh -c 'if [ ! -f /data/local/tmp/neogeo_bios.zip ]; then cp /data/data/com.retroemupouch.app/files/roms/NeoGeo/neogeo.zip /data/local/tmp/neogeo_bios.zip; fi; mkdir -p /data/data/com.retroemupouch.app/files/system/mame/roms && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/neogeo.zip && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/mame/roms/neogeo.zip && echo BIOS_STAGED'" *>> $blog 2>&1
    Log "bios-stage exit=$LASTEXITCODE"
    & $adb -s $d shell "run-as com.retroemupouch.app ls -la files/system/neogeo.zip files/system/mame/roms/neogeo.zip files/roms/NeoGeo/mslug.zip" *>> $blog 2>&1
} else {
    Log '--- skip NeoGeo BIOS staging (SeedBios disabled) ---'
}

# 4) mslug gate
Log '--- mslug gate ---'
& $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $adb -s $d shell logcat -c | Out-Null
& $adb -s $d shell am start -n com.retroemupouch.app/.EmulatorActivity --es bench_rom "roms/NeoGeo/mslug.zip" --es bench_core mame --ei bench_seconds 3 --es bench_id mslug_gate 2>&1 | Out-Null
$msl='TIMEOUT'
for ($i=0;$i -lt 8;$i++) {
    Start-Sleep -Seconds 2
    $lg = & $adb -s $d logcat -d -v brief 2>$null | Select-String -Pattern 'GS-runner.*\[pace\]|GS-CORE-FAIL|sfix|neogeo'
    if ($lg) {
        $ln = ($lg | Select-Object -Last 1).ToString()
        if ($ln -match 'GS-CORE-FAIL') { $msl='FAIL: ' + ($ln -replace '.*GS-CORE-FAIL ','') } else { $msl='PASS' }
        break
    }
}
& $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
Log "mslug-gate: $msl"

# Dump the most relevant diagnostic lines for the report.
& $adb -s $d logcat -d -v brief 2>$null |
    Select-String -Pattern 'GS-LockedRom|GS-CORE|sfix|neogeo|pace' |
    Select-Object -Last 25 | ForEach-Object { Log ("  log| " + $_.ToString()) }

Log "=== test-neogeo done $(Get-Date) ==="
