$ErrorActionPreference = 'Stop'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb  = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d    = '66B0219C18003002'
$blog = "$root\build\full2-build.log"
$csv  = "$root\build\verify_all.csv"
$so   = "$root\app\android\app\src\store\jniLibs\arm64-v8a\libgs_mame.so"

function Log($m){ $m | Out-File -Append -FilePath $blog -Encoding utf8 }
Log "=== full2 rebuild+verify start $(Get-Date) ==="

# ---- A) regenerate driver list inside WSL, with hard gate on neogeo ----
Log '--- regen driver list (gate: neogeo must be present) ---'
wsl.exe -e bash -lc 'cd ~/mame-build/mame && bash /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/scripts/mame/gen-subtarget.sh /home/ubuntu/mame-build/mame && if grep -qxF neogeo src/mame/gamepouch.lst; then echo GATE_OK neogeo_present; else echo GATE_FAIL neogeo_missing; exit 2; fi && rm -f build/generated/mame/gamepouch/drivlist.cpp && echo DRIVLIST_CLEARED' *>> $blog 2>&1
if ($LASTEXITCODE -ne 0) { Log 'ABORT: neogeo gate failed during regen'; exit 1 }

# ---- B) rebuild the MAME core ----
Log '--- build core ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-mame.ps1" -SkipClone -Jobs 8 -WslNdkPath /home/ubuntu/ndkdl/android-ndk-r28c *>> $blog 2>&1
Log "core build exit=$LASTEXITCODE"

# ---- C) gate: the built .so must contain the neogeo BIOS machine ----
Log '--- gate: .so contains neogeo BIOS machine ---'
$gate = wsl.exe -e bash -lc "grep -q 'Neo-Geo MV-6F' /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/app/android/app/src/store/jniLibs/arm64-v8a/libgs_mame.so && echo SO_OK || echo SO_FAIL"
Log "so-neogeo-gate: $gate"
if ($gate -notmatch 'SO_OK') { Log 'ABORT: built .so does not contain neogeo BIOS machine'; exit 1 }

# ---- D) build debug store APK ----
Log '--- build APK ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-apk.ps1" -Flavor store -DebugBuild -NoPubGet *>> $blog 2>&1
Log "apk build exit=$LASTEXITCODE"

# ---- E) install ----
$apk = "$root\app\build\app\outputs\flutter-apk\app-store-debug.apk"
Log "--- install $apk ---"
& $adb -s $d install -r $apk *>> $blog 2>&1

# ---- F) reseed ROMs + BIOS ----
Log '--- seed ---'
& $adb -s $d shell "run-as com.retroemupouch.app sh /data/local/tmp/seed.sh" *>> $blog 2>&1

# ---- G) gate: real-device mslug must boot (NeoGeo BIOS present) ----
Log '--- gate: mslug boots on device ---'
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
if ($msl -notmatch 'PASS') { Log 'ABORT: mslug did not boot on device (NeoGeo BIOS still missing)'; exit 1 }

# ---- H) full re-verification of all 224 games ----
Log '--- verify all 224 games ---'
[System.IO.File]::WriteAllText($csv, "dir,rom,status,reason`n", (New-Object System.Text.UTF8Encoding $false))
$pass=0;$fail=0;$total=0
foreach ($dir in @('Cps1','Cps2','NeoGeo')) {
    $roms = & $adb -s $d shell "run-as com.retroemupouch.app ls files/roms/$dir" 2>$null |
        Where-Object { $_ -match '\.zip$' -and $_ -notmatch '^neogeo\.zip$' } |
        ForEach-Object { $_.Trim() }
    foreach ($r in $roms) {
        & $adb -s $d logcat -c | Out-Null
        & $adb -s $d shell am start -n com.retroemupouch.app/.EmulatorActivity `
            --es bench_rom "roms/$dir/$r" --es bench_core mame `
            --ei bench_seconds 2 --es bench_id "v_$r" 2>&1 | Out-Null
        $st='TIMEOUT'; $rs=''
        for ($k=0; $k -lt 6; $k++) {
            Start-Sleep -Seconds 2
            $lg = & $adb -s $d logcat -d -v brief 2>$null | Select-String -Pattern 'GS-runner.*\[pace\]|GS-CORE-FAIL'
            if ($lg) {
                $ln = ($lg | Select-Object -Last 1).ToString()
                if ($ln -match 'GS-CORE-FAIL') { $st='FAIL'; $rs=($ln -replace '.*GS-CORE-FAIL ','').Replace(',',';') } else { $st='PASS' }
                break
            }
        }
        if ($st -eq 'TIMEOUT') { $rs='no-frames/timeout' }
        if ($st -eq 'PASS') { $pass++ } else { $fail++ }
        $total++
        [System.IO.File]::AppendAllText($csv, ('{0},{1},{2},{3}' -f $dir,$r,$st,$rs)+"`n", (New-Object System.Text.UTF8Encoding $false))
        & $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
    }
    Log "$dir done (total=$total pass=$pass fail=$fail)"
}
Log "VERIFY TOTAL=$total PASS=$pass FAIL=$fail"

# ---- I) regenerate lists ----
Log '--- regenerate lists ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\build\gen-lists.ps1" *>> $blog 2>&1
Log "=== full2 rebuild+verify done $(Get-Date) ==="
