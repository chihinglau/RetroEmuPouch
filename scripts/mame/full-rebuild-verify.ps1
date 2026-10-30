$ErrorActionPreference = 'Stop'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb  = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d    = '66B0219C18003002'
$blog = "$root\build\full-build.log"
$csv  = "$root\build\verify_all.csv"
$seed = "$root\build/seed.sh"

function Log($m){ $m | Out-File -Append -FilePath $blog -Encoding utf8 }

Log "=== full rebuild+verify start $(Get-Date) ==="

# 1) regenerate driver list (now includes the CONS() NeoGeo BIOS machine)
Log '--- gen-subtarget ---'
wsl.exe -e bash -lc 'cd ~/mame-build/mame && bash /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/scripts/mame/gen-subtarget.sh /home/ubuntu/mame-build/mame' *>> $blog 2>&1
if (wsl.exe -e bash -lc 'cd ~/mame-build/mame && grep -qxE neogeo src/mame/gamepouch.lst') { Log 'OK: neogeo BIOS machine present in lst' } else { Log 'ERROR: neogeo NOT in lst' }

# 2) rebuild the MAME core (.so)
Log '--- build core ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-mame.ps1" -SkipClone -Jobs 8 -WslNdkPath /home/ubuntu/ndkdl/android-ndk-r28c *>> $blog 2>&1
Log "core build exit=$LASTEXITCODE"

# 3) build debug store APK (bundles new .so)
Log '--- build APK ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-apk.ps1" -Flavor store -DebugBuild -NoPubGet *>> $blog 2>&1
Log "apk build exit=$LASTEXITCODE"

# 4) install on OXF (signature matches -> data wiped, reseed after)
$apk = "$root\app\build\app\outputs\flutter-apk\app-store-debug.apk"
Log "--- install $apk ---"
& $adb -s $d install -r $apk *>> $blog 2>&1

# 5) reseed ROMs + BIOS
Log '--- seed ---'
& $adb -s $d shell "run-as com.retroemupouch.app sh /data/local/tmp/seed.sh" *>> $blog 2>&1

# 6) full re-verification of all 224 games on OXF
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

# 7) regenerate lists
Log '--- regenerate lists ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\build\gen-lists.ps1" *>> $blog 2>&1

Log "=== full rebuild+verify done $(Get-Date) ==="
