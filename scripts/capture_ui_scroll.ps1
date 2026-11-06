$root='D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$sn='2MN0224730027764'
$hdc='D:\HuaWei\OhosSdkForFlutter\26\toolchains\hdc.exe'
$assets="$root\docs\soft-copyright\assets"

& $hdc -t $sn shell "power-shell timeout -o 1800000" | Out-Null
& $hdc -t $sn shell "power-shell setmode 600" | Out-Null

& $hdc -t $sn shell "aa force-stop com.retroemupouch.app" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $hdc -t $sn shell "aa start -a EntryAbility -b com.retroemupouch.app" 2>&1 | Out-Null
Start-Sleep -Seconds 8
& $hdc -t $sn shell "uitest uiInput click 1171 223" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $hdc -t $sn shell "uitest uiInput click 630 1956" 2>&1 | Out-Null
Start-Sleep -Seconds 3
# 向上滑动一屏，露出 虚拟手柄布局 / BIOS 管理 / 通用
& $hdc -t $sn shell "uitest uiInput swipe 630 2300 630 900 600" 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $hdc -t $sn shell "snapshot_display -f /data/local/tmp/p2.jpeg" 2>&1 | Out-Null
& $hdc -t $sn file recv /data/local/tmp/p2.jpeg "$assets\personalize2.jpeg" 2>&1 | Out-Null
& $hdc -t $sn shell "rm -f /data/local/tmp/p2.jpeg" 2>&1 | Out-Null
Write-Output 'captured personalize2'
Get-Item "$assets\personalize2.jpeg" | Select-Object Name,Length
