$ErrorActionPreference = 'Stop'
$root   = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$adb     = "$root\.tools\android-sdk\platform-tools\adb.exe"
$d       = '66B0219C18003002'
$blog    = "$root\build\mame-rebuild.log"
$flog    = "$root\build\finish.log"
$csv     = "$root\build\verify_all.csv"
$outcsv  = "$root\build\verify_all2.csv"

function Log($m){ $m | Out-File -Append -FilePath $flog -Encoding utf8 }

Log "=== finish pipeline start $(Get-Date) ==="

# 1) wait for the core rebuild to finish (up to ~8h)
$built = $false
for ($i=0; $i -lt 960; $i++) {
    if (Test-Path $blog) {
        $c = Get-Content -Encoding UTF8 $blog -Tail 3
        if ($c -match 'build exit 0') { $built = $true; Log 'core build finished (exit 0)'; break }
        if ($c -match 'ERROR:')       { Log 'core build FAILED'; throw 'core build failed' }
    }
    Start-Sleep -Seconds 30
}
if (-not $built) { Log 'TIMEOUT waiting for core build'; throw 'timeout' }

# 2) rebuild debug store APK (bundles the new .so)
Log '--- build debug store APK ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-apk.ps1" -Flavor store -DebugBuild -NoPubGet 2>&1 | ForEach-Object { Log $_ }

# 3) install on OXF
$apk = "$root\app\build\app\outputs\flutter-apk\app-store-debug.apk"
Log "--- install $apk ---"
& $adb -s $d install -r $apk 2>&1 | ForEach-Object { Log $_ }

# 4) reseed ROMs (BIOS + games) from local cache
Log '--- seed ROMs ---'
& $adb -s $d shell "run-as com.retroemupouch.app sh /data/local/tmp/seed.sh" 2>&1 | ForEach-Object { Log $_ }

# 5) full re-verification of all 224 games on OXF
Log '--- verify all 224 games ---'
[System.IO.File]::WriteAllText($outcsv, "dir,rom,status,reason`n", (New-Object System.Text.UTF8Encoding $false))
$pass=0;$fail=0;$total=0
foreach ($dir in @('Cps1','Cps2','NeoGeo')) {
    $roms = & $adb -s $d shell "run-as com.retroemupouch.app ls files/roms/$dir" 2>$null |
        Where-Object { $_ -match '\.zip$' -and $_ -notmatch '^neogeo\.zip$' } |
        ForEach-Object { $_.Trim() }
    foreach ($r in $roms) {
        & $adb -s $d logcat -c | Out-Null
        & $adb -s $d shell am start -n com.retroemupouch.app/.EmulatorActivity `
            --es bench_rom "roms/$dir/$r" --es bench_core mame `
            --ei bench_seconds 2 --es bench_id "v2_$r" 2>&1 | Out-Null
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
        [System.IO.File]::AppendAllText($outcsv, ('{0},{1},{2},{3}' -f $dir,$r,$st,$rs)+"`n", (New-Object System.Text.UTF8Encoding $false))
        & $adb -s $d shell am force-stop com.retroemupouch.app 2>&1 | Out-Null
    }
    Log "$dir done (total=$total pass=$pass fail=$fail)"
}
Log "VERIFY TOTAL=$total PASS=$pass FAIL=$fail"

# 6) regenerate lists from the new results
Copy-Item $outcsv $csv -Force
Log '--- regenerate lists ---'
& powershell.exe -ExecutionPolicy Bypass -File "$root\build\gen-lists.ps1" 2>&1 | ForEach-Object { Log $_ }

Log "=== finish pipeline done $(Get-Date) ==="
