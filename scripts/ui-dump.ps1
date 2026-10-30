# 用法: .\scripts\ui-dump.ps1 -Serial <sn> [-OutFile path] [-TapOn <文本片段>]
param(
  [Parameter(Mandatory = $true)] [string] $Serial,
  [string] $OutFile,
  [string] $TapOn
)

$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
if (-not $env:ANDROID_HOME) {
  . (Join-Path $PSScriptRoot 'use-env.ps1') | Out-Null
  $adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
}

& $adb -s $Serial shell uiautomator dump /sdcard/ui.xml | Out-Null
$xmlTxt = & $adb -s $Serial shell cat /sdcard/ui.xml
$xmlTxt = ($xmlTxt -join "`n")
# adb shell 会把换行写成 \r\n，PowerShell 数组元素自带换行，统一清洗
$xmlTxt = $xmlTxt -replace "`r", ""
$start = $xmlTxt.IndexOf('<?xml')
if ($start -lt 0) { $start = $xmlTxt.IndexOf('<hierarchy') }
$xmlTxt = $xmlTxt.Substring($start)

[xml]$x = $xmlTxt
$nodes = @($x.hierarchy.node)
$flat = New-Object System.Collections.Generic.List[object]
function Flatten($n) {
  if (-not $n) { return }
  foreach ($c in @($n.node)) { Flatten $c }
  $flat.Add($n) | Out-Null
}
foreach ($n in $nodes) { Flatten $n }

$rows = $flat | Where-Object { $_.text -ne '' -or $_.'content-desc' -ne '' } |
  ForEach-Object {
    $b = $_.bounds
    $cx = 0; $cy = 0
    if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $cx = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
      $cy = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
    }
    [pscustomobject]@{
      text    = $_.text
      desc    = $_.'content-desc'
      cx      = $cx
      cy      = $cy
      bounds  = $b
      cls     = $_.class
      click   = $_.clickable
    }
  }

if ($OutFile) { $rows | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $OutFile }

$rows | Format-Table -AutoSize -Property text, desc, cx, cy, click | Out-String -Width 220

if ($TapOn) {
  $hit = $rows | Where-Object { $_.text -like "*$TapOn*" -or $_.desc -like "*$TapOn*" } | Select-Object -First 1
  if ($hit) {
    Write-Output "[tap] $($hit.text)/$($hit.desc) @ $($hit.cx),$($hit.cy)"
    & $adb -s $Serial shell input tap $hit.cx $hit.cy
  }
  else { Write-Output "[tap] NOT FOUND: $TapOn" }
}
