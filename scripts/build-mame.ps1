#requires -Version 5.1
<#
  Build the libretro MAME core for android-arm64 and install it as
  `libgs_mame.so` into the **store** flavour only (R13 / R3).

  Why MAME: FBA-2012 / FinalBurn Neo are NON-COMMERCIAL and must never ship in
  a store build. MAME >= 0.197 is dual-licensed BSD-3-Clause / GPL-2.0-or-later,
  so the BSD option makes commercial distribution possible (attribution only).

  The build runs **inside WSL**: MAME's build system (genie + GNU make + the
  Android NDK clang toolchain) is Unix-oriented. There is no supported native
  Windows path, and running make against a Windows-mounted drive from WSL is
  dramatically slower, so the source is cloned into WSL's *native* filesystem.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-mame.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-mame.ps1 -Ref mame0289 -Jobs 8
    powershell -ExecutionPolicy Bypass -File scripts\build-mame.ps1 -SkipClone   # rebuild only

  Prerequisites (inside the WSL distro):
    sudo apt-get update && sudo apt-get install -y git make python3 unzip patch

  NOTE: the first full build compiles several thousand translation units and
  takes **hours**. Budget disk (>= 15 GB free for objects + source).
#>
[CmdletBinding()]
param(
  # Git ref to build. 'master' tracks current MAME (well past 0.197).
  # Pin an explicit tag/commit for reproducible release builds.
  [string]$Ref = 'master',

  # Parallel make jobs. 0 = use all WSL-visible cores.
  [int]$Jobs = 0,

  # Reuse the already-cloned tree (no fetch/pull).
  [switch]$SkipClone,

  # Clone inside WSL instead of on the Windows host. Use this only when WSL
  # has direct github.com connectivity (by default it often does not, while
  # the Windows host does).
  [switch]$CloneInWsl,

  # Override the NDK directory (default: newest under .tools\android-sdk\ndk).
  [string]$NdkDir,

  # Build only a driver subset. `gamepouch` compiles just the manufacturer
  # folders referenced by the app's multiplayer catalog (snk + capcom), which
  # keeps the core to a few tens of MB instead of ~420 MB. Leave empty for the
  # full MAME driver set.
  [string]$Subtarget,

  # Path to a **Linux** NDK that already lives inside WSL (e.g.
  # /home/ubuntu/android-ndk-r28c). Required when building in WSL: the NDK
  # shipped with the Windows Android SDK only contains a windows-x86_64
  # toolchain, which genie cannot use (it reports "Clang version 13 or later
  # needed" because it cannot find a linux-x86_64 clang).
  [string]$WslNdkPath
)

$ErrorActionPreference = 'Stop'

$Root  = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { (Resolve-Path '.').Path }
$Tools = Join-Path $Root '.tools'
$RepoUrl = 'https://github.com/libretro/mame'

# ---- 1. locate the Android NDK ---------------------------------------------
if ($WslNdkPath) {
  Write-Host "[ndk] WSL-native NDK: $WslNdkPath" -ForegroundColor Cyan
} else {
  if (-not $NdkDir) {
    $ndkBase = Join-Path $Tools 'android-sdk\ndk'
    if (-not (Test-Path $ndkBase)) { throw "NDK not found at $ndkBase" }
    $newest = Get-ChildItem -LiteralPath $ndkBase -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d' } |
              Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw "No NDK version directory under $ndkBase" }
    $NdkDir = $newest.FullName
  }
  if (-not (Test-Path $NdkDir)) { throw "NDK directory does not exist: $NdkDir" }
  Write-Host "[ndk] $NdkDir (Windows NDK - only usable with -CloneInWsl off? no: needs linux toolchain)" -ForegroundColor Yellow
}

# ---- 2. WSL sanity check ---------------------------------------------------
function Invoke-Wsl {
  param([Parameter(Mandatory = $true)][string]$Command)
  # Native commands writing to stderr (wsl/git progress banners) would become
  # terminating errors under ErrorActionPreference=Stop. Scope them to
  # 'Continue' and rely on $LASTEXITCODE instead.
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & wsl.exe -e bash -lc $Command
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEap
  }
  if ($code -ne 0) { throw "WSL command failed ($code): $Command" }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw 'WSL is required but was not found. Install a distro (wsl --install) and retry.'
}

Write-Host '==> checking WSL distro and build tools' -ForegroundColor Cyan
try { Invoke-Wsl 'echo ok' } catch { throw 'No usable WSL distro. Run: wsl --install' }
foreach ($tool in @('git', 'make', 'python3')) {
  try { Invoke-Wsl "command -v $tool" } catch { throw "WSL is missing '$tool'. Install with: sudo apt-get install -y $tool" }
}

# ---- 3. paths --------------------------------------------------------------
function ConvertTo-WslPath {
  param([Parameter(Mandatory = $true)][string]$WindowsPath)
  $full = (Resolve-Path -LiteralPath $WindowsPath).Path
  $drive = $full.Substring(0, 1).ToLower()
  $rest  = $full.Substring(2).Replace('\', '/')
  return "/mnt/$drive$rest"
}

$wslNdk   = if ($WslNdkPath) { $WslNdkPath.TrimEnd('/') } else { ConvertTo-WslPath $NdkDir }
$wslHome  = (& wsl.exe -e bash -lc 'echo $HOME').Trim()
if ([string]::IsNullOrWhiteSpace($wslHome)) { $wslHome = '/root' }
$wslWork  = "$wslHome/mame-build"          # native FS: much faster than /mnt
$wslSrc   = "$wslWork/mame"
$wslOut   = "$wslWork/out"

$destDir  = Join-Path $Root 'app\android\app\src\store\jniLibs\arm64-v8a'
$destFile = Join-Path $destDir 'libgs_mame.so'

Write-Host "[work] WSL source dir : $wslSrc" -ForegroundColor Cyan
Write-Host "[work] output library : $destFile" -ForegroundColor Cyan

# ---- 4. fetch source -------------------------------------------------------
if ($SkipClone) {
  Write-Host '==> skipping clone (-SkipClone)' -ForegroundColor Cyan
} elseif ($CloneInWsl) {
  Write-Host "==> fetching $RepoUrl @ $Ref (inside WSL)" -ForegroundColor Cyan
  Invoke-Wsl "mkdir -p '$wslWork'"
  Invoke-Wsl "rm -rf '$wslSrc'"
  # Shallow clone: the full history is ~2 GB and is not needed to build.
  Invoke-Wsl "git clone --depth 1 --branch '$Ref' '$RepoUrl' '$wslSrc' 2>&1 | tail -5"
  # Pull any submodules the core needs (no-op when there are none).
  Invoke-Wsl "cd '$wslSrc' && git submodule update --init --recursive --depth 1 2>&1 | tail -20"
} else {
  # WSL commonly cannot reach github.com even when the Windows host can.
  # Clone on the host, then copy into WSL's *native* filesystem: building
  # directly off /mnt is dramatically slower.
  Write-Host "==> fetching $RepoUrl @ $Ref (host git, then into WSL)" -ForegroundColor Cyan
  $winSrc = Join-Path $Root 'build\mame-src'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $winSrc) | Out-Null
  if (Test-Path -LiteralPath $winSrc) { Remove-Item -LiteralPath $winSrc -Recurse -Force }
  # git prints "Cloning into ..." to stderr, which under
  # ErrorActionPreference=Stop aborts the script. Scope it to 'Continue'.
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git.exe clone --depth 1 --branch $Ref $RepoUrl $winSrc 2>&1 | Select-Object -Last 5
    if ($LASTEXITCODE -ne 0) {
      throw "git clone failed ($LASTEXITCODE). Check host connectivity, or retry with -CloneInWsl."
    }
    & git.exe -C $winSrc submodule update --init --recursive --depth 1 2>&1 | Select-Object -Last 10
  } finally {
    $ErrorActionPreference = $oldEap
  }
  $wslWinSrc = ConvertTo-WslPath $winSrc
  Invoke-Wsl "rm -rf '$wslSrc'; mkdir -p '$wslWork'"
  Write-Host '==> copying source into WSL native filesystem' -ForegroundColor Cyan
  Invoke-Wsl "cp -a '$wslWinSrc' '$wslSrc' && echo COPY_OK"
}

# ---- 5. build --------------------------------------------------------------
if ($Jobs -le 0) {
  $cores = (& wsl.exe -e bash -lc 'nproc').Trim()
  if ($cores -notmatch '^\d+$') { $cores = 4 }
  $Jobs = [int]$cores
}
Write-Host "==> make -f Makefile.libretro platform=android-arm64 -j $Jobs (this takes hours)" -ForegroundColor Cyan

# NOWERROR=1: newer NDK/clang emit warnings that would otherwise abort the build.
$subtargetArg = if ($Subtarget) { "SUBTARGET=$Subtarget " } else { "" }
Invoke-Wsl "cd '$wslSrc' && export ANDROID_NDK_ROOT='$wslNdk' && export ANDROID_NDK_HOME='$wslNdk' && make -f Makefile.libretro platform=android-arm64 NOWERROR=1 ${subtargetArg}-j $Jobs 2>&1 | tail -60"

# ---- 6. locate and install the produced core -------------------------------
Write-Host '==> locating built libretro core' -ForegroundColor Cyan
# Pick the NEWEST match by mtime: a stale .so from a previous SUBTARGET build
# can sit next to the fresh one (e.g. mamegamepouch_libretro_android.so from an
# earlier run), and find's directory order is not recency order. Shipping the
# stale file silently loses whatever the incremental build just changed.
$so = (& wsl.exe -e bash -lc "find '$wslSrc' -name '*libretro*.so' -type f -printf '%T@ %p\n' | sort -rn | head -5 | cut -d' ' -f2-").Trim()
if ([string]::IsNullOrWhiteSpace($so)) {
  throw "Build finished but no '*libretro*.so' was found under $wslSrc. Inspect the make output above."
}
$soFirst = ($so -split "`n")[0].Trim()
Write-Host "[build] produced: $soFirst" -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Invoke-Wsl "mkdir -p '$wslOut' && cp '$soFirst' '$wslOut/libgs_mame.so'"

$wslDestDir  = ConvertTo-WslPath $destDir
$wslDestFile = "$wslDestDir/libgs_mame.so"
Invoke-Wsl "mkdir -p '$wslDestDir' && cp '$wslOut/libgs_mame.so' '$wslDestFile'"

# strip debug symbols to keep the APK reasonable
Invoke-Wsl "command -v llvm-strip >/dev/null 2>&1 && llvm-strip --strip-unneeded '$wslDestFile' || true"

# ---- 7. verify -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $destFile)) { throw "Install failed: $destFile not created" }
$len = [math]::Round((Get-Item -LiteralPath $destFile).Length / 1MB, 1)
Write-Host "==> installed libgs_mame.so ($len MB) -> $destFile" -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Flip the arcade core id for the store channel in app/lib/domain/rom_entry.dart'
Write-Host "     (PlatformKind.mame / neogeo -> 'mame' instead of null)."
Write-Host '  2. Add MAME to app/assets/OSS_LICENSES.md with the exact source ref used here.'
Write-Host '  3. Re-run: powershell -ExecutionPolicy Bypass -File scripts\ci.ps1 -Flavor store'
Write-Host '     (the store gate asserts the non-commercial FBA core is absent).'
Write-Host ''
Write-Host "Built from ref: $Ref" -ForegroundColor Cyan
