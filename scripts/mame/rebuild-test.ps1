$ErrorActionPreference = 'Stop'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb  = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d    = '66B0219C18003002'
$blog = "$root\build\rebuild-test.log"

# NeoGeo BIOS source on the host. Override with $env:NEOGEO_ZIP if your copy
# lives elsewhere. Must be a FULL MAME 0.289 (or compatible) neogeo.zip whose
# 000-lo.lo/sfix.sfix/sm1.sm1/sp-s2.sp1 CRCs match the built core.
$neogeoZip = if ($env:NEOGEO_ZIP) { $env:NEOGEO_ZIP } else {
    'G:\software\game\mame\MAME 0.289 ROMs (bios-devices)\neogeo.zip'
}

# Deploy the NeoGeo BIOS onto a TEST device's private filesystem so the MAME core
# can find it. This is for LOCAL/TEST use ONLY — it never packages BIOS into the
# APK (commercial builds must not ship ROM/BIOS; see check-apk-content.ps1).
# Keep this $false in CI / release pipelines so no copyrighted BIOS is ever
# handled there. Override with $env:SEED_BIOS = '0' to disable.
$SeedBios = if ($env:SEED_BIOS) { $env:SEED_BIOS -ne '0' } else { $true }

function Log($m){ $m | Out-File -Append -FilePath $blog -Encoding utf8 }
Log "=== rebuild+test start $(Get-Date) ==="

# 1) force recompile of capcom+snk drivers (so neogeo BIOS machine gets registered)
Log '--- force recompile snk+capcom objects ---'
wsl.exe -e bash -lc 'rm -rf ~/mame-build/mame/build/libretro/obj/libretro/src/mame/snk ~/mame-build/mame/build/libretro/obj/libretro/src/mame/capcom && echo OBJ_CLEARED' *>> $blog 2>&1

# 2) regenerate driver list, gate on neogeo
Log '--- regen lst (gate neogeo) ---'
wsl.exe -e bash -lc 'cd ~/mame-build/mame && bash /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/scripts/mame/gen-subtarget.sh /home/ubuntu/mame-build/mame && if grep -qxF neogeo src/mame/gamepouch.lst; then echo GATE_OK; else echo GATE_FAIL; exit 2; fi' *>> $blog 2>&1
if ($LASTEXITCODE -ne 0) { Log 'ABORT: neogeo gate'; exit 1 }

# 3) rebuild core
Log '--- build core ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-mame.ps1" -SkipClone -Jobs 8 -WslNdkPath /home/ubuntu/ndkdl/android-ndk-r28c *>> $blog 2>&1
Log "core build exit=$LASTEXITCODE"

# 4) APK + install + seed
Log '--- build APK ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-apk.ps1" -Flavor store -DebugBuild -NoPubGet *>> $blog 2>&1
Log "apk exit=$LASTEXITCODE"
$apk = "$root\app\build\app\outputs\flutter-apk\app-store-debug.apk"
Log "--- install ---"
& $adb -s $d install -r $apk *>> $blog 2>&1
Log '--- seed ---'
& $adb -s $d shell "run-as com.retroemupouch.app sh /data/local/tmp/seed.sh" *>> $blog 2>&1

# 4b) Stage the NeoGeo BIOS where the libretro MAME core actually searches it.
#     The core's rompath is: <content_dir>; <system>/mame/bios; <system>/mame/roms.
#     For MAME the game content lands in rom_cache/mame, so we must place
#     neogeo.zip in system/neogeo.zip (the authoritative source the app copies
#     from, once LockedRom.kt is fixed) AND in system/mame/roms/neogeo.zip which
#     the core always scans, as a belt-and-suspenders fallback.
#     LOCAL/TEST ONLY — gated by $SeedBios so CI/release never ships BIOS.
if ($SeedBios) {
Log '--- stage NeoGeo BIOS (system/neogeo.zip + system/mame/roms) ---'
if (Test-Path $neogeoZip) {
    & $adb -s $d push "$neogeoZip" /data/local/tmp/neogeo_bios.zip *>> $blog 2>&1
    Log "push local neogeo.zip exit=$LASTEXITCODE"
} else {
    Log "WARN: local neogeo.zip not found at '$neogeoZip'; will reuse a device copy if present"
}
# If a local copy was not pushed, fall back to the device's own seed copy
# (files/roms/NeoGeo/neogeo.zip). Then copy it into the two locations the core
# scans. BIOS_STAGED on success.
& $adb -s $d shell "run-as com.retroemupouch.app sh -c 'if [ ! -f /data/local/tmp/neogeo_bios.zip ]; then cp /data/data/com.retroemupouch.app/files/roms/NeoGeo/neogeo.zip /data/local/tmp/neogeo_bios.zip; fi; mkdir -p /data/data/com.retroemupouch.app/files/system/mame/roms && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/neogeo.zip && cp /data/local/tmp/neogeo_bios.zip /data/data/com.retroemupouch.app/files/system/mame/roms/neogeo.zip && echo BIOS_STAGED'" *>> $blog 2>&1
Log "bios-stage exit=$LASTEXITCODE"
& $adb -s $d shell "run-as com.retroemupouch.app ls -la files/system/neogeo.zip files/system/mame/roms/neogeo.zip" *>> $blog 2>&1
} else {
    Log '--- skip NeoGeo BIOS staging (SeedBios disabled) ---'
}

# 5) mslug gate (log only, do not abort)
Log '--- mslug gate ---'
& $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $adb -s $d logcat -c | Out-Null
& $adb -s $d shell am start -n com.retroemupouch.app/.EmulatorActivity --es bench_rom "roms/NeoGeo/mslug.zip" --es bench_core mame --ei bench_seconds 3 --es bench_id mslug_gate 2>&1 | Out-Null
$msl='TIMEOUT'
for ($i=0;$i -lt 7;$i++) {
    Start-Sleep -Seconds 2
    $lg = & $adb -s $d logcat -d -v brief 2>$null | Select-String -Pattern 'GS-runner.*\[pace\]|GS-CORE-FAIL'
    if ($lg) {
        $ln = ($lg | Select-Object -Last 1).ToString()
        if ($ln -match 'GS-CORE-FAIL') { $msl='FAIL: ' + ($ln -replace '.*GS-CORE-FAIL ','') } else { $msl='PASS' }
        break
    }
}
& $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
Log "mslug-gate: $msl"
Log "=== rebuild+test done $(Get-Date) ==="
