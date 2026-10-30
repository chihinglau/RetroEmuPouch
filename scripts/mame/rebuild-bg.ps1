$ErrorActionPreference = 'Stop'
$root = 'D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$log  = "$root\build\mame-rebuild.log"
function Log($m) { $m | Out-File -Append -FilePath $log -Encoding utf8 }

Log "=== start $(Get-Date) ==="
try {
    Log '--- generate subtarget (extended capcom+snk driver set) ---'
    & wsl.exe -e bash -lc "bash /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/scripts/mame/gen-subtarget.sh /home/ubuntu/mame-build/mame" 2>&1 | ForEach-Object { Log $_ }
    Log "--- gen exit $LASTEXITCODE ---"

    Log '--- build MAME core (gamepouch subtarget) ---'
    & powershell.exe -ExecutionPolicy Bypass -File "$root\scripts\build-mame.ps1" -Subtarget gamepouch -SkipClone -Jobs 8 -WslNdkPath /home/ubuntu/ndkdl/android-ndk-r28c 2>&1 | ForEach-Object { Log $_ }
    Log "--- build exit $LASTEXITCODE ---"
} catch {
    Log "ERROR: $_"
}
Log "=== done $(Get-Date) ==="
