# build-mame-ohos-wsl.ps1
# Single Windows command to build the HarmonyOS MAME core via WSL.
# No manual `cd` between Windows and WSL: all setup lives in
# build/mame-ohos-src/run_build.sh. Logs to build/mame-ohos-src/build_run.txt.
param(
  [ValidateSet('build','precompile')] [string]$Mode = 'build',
  [switch]$ClearD,
  [int]$Jobs
)
$ErrorActionPreference = 'Stop'
$clear = if ($ClearD) { '1' } else { '0' }
$jobsArg = if ($Jobs -gt 0) { [string]$Jobs } else { '' }
$sh = '/mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/build/mame-ohos-src/run_build.sh'
Write-Host ">> HarmonyOS MAME build ($Mode) — log: build\mame-ohos-src\build_run.txt"
$envLine = "OHOS_CLEAR_D=$clear"
if ($jobsArg) { $envLine += " OHOS_JOBS=$jobsArg" }
wsl.exe -e bash -c "$envLine bash $sh $Mode"
