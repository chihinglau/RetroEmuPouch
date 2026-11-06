$root='D:\ai\prj\trae\HuaWei\RetroEmuPouch'
$sn='2MN0224730027764'
$hdc='D:\HuaWei\OhosSdkForFlutter\26\toolchains\hdc.exe'
$assets="$root\docs\soft-copyright\assets"
New-Item -ItemType Directory -Force $assets | Out-Null

& $hdc -t $sn shell "power-shell timeout -o 1800000" | Out-Null
& $hdc -t $sn shell "power-shell setmode 600" | Out-Null

# 分支: 名称, 目标坐标（基于设置面板布局，比例 1260/480=2.625）
$branches = @(
  @{ name='personalize'; x=630;  y=1956 },
  @{ name='about';       x=630;  y=2244 },
  @{ name='tutorial';    x=630;  y=800  }
)

foreach ($b in $branches) {
  & $hdc -t $sn shell "aa force-stop com.retroemupouch.app" 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  & $hdc -t $sn shell "aa start -a EntryAbility -b com.retroemupouch.app" 2>&1 | Out-Null
  Start-Sleep -Seconds 8
  # 打开设置面板（右上角齿轮）
  & $hdc -t $sn shell "uitest uiInput click 1171 223" 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  # 点目标条目
  & $hdc -t $sn shell "uitest uiInput click $($b.x) $($b.y)" 2>&1 | Out-Null
  Start-Sleep -Seconds 3
  & $hdc -t $sn shell "snapshot_display -f /data/local/tmp/$($b.name).jpeg" 2>&1 | Out-Null
  & $hdc -t $sn file recv "/data/local/tmp/$($b.name).jpeg" "$assets\$($b.name).jpeg" 2>&1 | Out-Null
  & $hdc -t $sn shell "rm -f /data/local/tmp/$($b.name).jpeg" 2>&1 | Out-Null
  Write-Output "captured $($b.name)"
}
Get-ChildItem $assets | Select-Object Name,Length
