#requires -Version 5.1
<#
  Build the libretro MAME core for HarmonyOS (OHOS) arm64 and install it as
  `libgs_mame.so` into cores/ohos/build/.

  SOURCE ISOLATION (hard requirement):
    * The shared Android MAME source at build/mame-src is NEVER modified.
    * We build from an isolated git worktree at build/mame-ohos-src (branch
      ohos-build). Targeted changes (the Makefile.libretro ohos-arm64 block and
      the clang wrapper scripts) live ONLY inside that worktree.
    * WSL's own filesystem is left alone: the Android build uses ~/mame-build;
      this script builds from the Windows-side worktree via /mnt and puts the
      toolchain wrappers inside the worktree, so nothing is written into WSL's
      home or native FS.

  Why a Windows clang via WSL interop:
    The OHOS SDK here ships a Windows clang.exe (D:\HuaWei\Sdk\<ver>\native\...).
    It cannot read the WSL native filesystem, so the source must stay on the
    Windows side (the worktree) and be reached through /mnt. WSL interop
    transparently translates /mnt/d/... paths to D:\... for the Windows binary.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-mame-ohos.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-mame-ohos.ps1 -Subtarget gamepouch -Jobs 8
    powershell -ExecutionPolicy Bypass -File scripts\build-mame-ohos.ps1 -Clean   # rebuild worktree

  Prerequisites (inside the WSL distro):
    sudo apt-get update && sudo apt-get install -y git make python3
#>
[CmdletBinding()]
param(
  # Parallel make jobs. 0 = use all WSL-visible cores.
  [int]$Jobs = 0,

  # Driver subset. 'arcade' uses the libretro-standard arcade filter (arcade.flt:
  # excludes mechanical/casino/etc., covers CPS1/CPS2/NeoGeo) -- a sane, supported
  # subset that still runs the app's catalog. Leave empty ('') for the full MAME
  # driver set. A tighter 'gamepouch' (snk+capcom only) subset can be added later
  # by dropping scripts/target/mame/gamepouch.lua into the isolated worktree.
  [string]$Subtarget = 'arcade',

  # Recreate the isolated worktree from scratch (discards any local edits there).
  [switch]$Clean,

  # OHOS SDK root (contains <OhosVersion>\native\llvm\bin\clang.exe).
  [string]$OhosSdkHome = 'D:\HuaWei\Sdk',

  # OHOS SDK version directory name.
  [string]$OhosVersion = '26.0.0',

  # Shared Android MAME source (read-only input; never modified).
  [string]$MameSrc = 'build\mame-src',

  # Isolated worktree used for the OHOS build (created from $MameSrc).
  [string]$WorkSrc = 'build\mame-ohos-src'
)

$ErrorActionPreference = 'Stop'

$Root     = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { (Resolve-Path '.').Path }
$MameSrc  = Join-Path $Root $MameSrc
$WorkSrc  = Join-Path $Root $WorkSrc
$OhosTc   = Join-Path $WorkSrc 'ohos-tc'

$clangExe = Join-Path $OhosSdkHome (Join-Path $OhosVersion 'native\llvm\bin\clang.exe')
$clangCpp = Join-Path $OhosSdkHome (Join-Path $OhosVersion 'native\llvm\bin\clang++.exe')
$llvmBin  = Join-Path $OhosSdkHome (Join-Path $OhosVersion 'native\llvm\bin')
$sysroot  = (Join-Path $OhosSdkHome (Join-Path $OhosVersion 'native\sysroot')).Replace('\', '/')
# Windows-form path for the Windows clang to read directly (WSL interop only
# translates /mnt/... args; a D:/ path is passed through untouched).
$sysrootWin = (Join-Path $OhosSdkHome (Join-Path $OhosVersion 'native\sysroot')).Replace('\', '/')

if (-not (Test-Path -LiteralPath $clangExe)) { throw "OHOS clang not found: $clangExe" }

# ---- 1. WSL sanity --------------------------------------------------------
function Invoke-Wsl {
  param([Parameter(Mandatory = $true)][string]$Command)
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

# ---- 2. isolated source copy (git-less) -----------------------------------
# The shared Android source (build/mame-src) is NEVER modified. We make a plain
# copy into build/mame-ohos-src and EXCLUDE .git: MAME's build probes `git
# describe`, and a git *worktree* created by Windows git stores a Windows-style
# gitdir path that the WSL git (used during the build) cannot resolve. A git-less
# copy sidesteps that and matches the "copy a separate source" requirement.
$isWorktree = Test-Path (Join-Path $WorkSrc '.git')
if ($isWorktree) {
  Write-Host '==> removing previous git worktree (Windows-git path conflicts with WSL git)' -ForegroundColor Cyan
  & git.exe -C $MameSrc worktree remove --force $WorkSrc 2>&1 | Select-Object -Last 2
  Remove-Item -LiteralPath $WorkSrc -Recurse -Force
} elseif ($Clean -and (Test-Path -LiteralPath $WorkSrc)) {
  Write-Host '==> -Clean: removing existing copy' -ForegroundColor Cyan
  Remove-Item -LiteralPath $WorkSrc -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkSrc 'Makefile'))) {
  Write-Host "==> copying $MameSrc -> $WorkSrc (excluding .git)" -ForegroundColor Cyan
  # robocopy mirrors the tree; /XD .git keeps the copy git-less.
  robocopy.exe $MameSrc $WorkSrc /MIR /XD .git /NFL /NDL /NJH /NJS
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }
  if (-not (Test-Path -LiteralPath (Join-Path $WorkSrc 'Makefile'))) {
    throw "Copy failed; $WorkSrc/Makefile missing."
  }
} else {
  Write-Host "==> reusing existing copy $WorkSrc" -ForegroundColor Cyan
}

# ---- 2.5 reset the files we patch to a clean base -------------------------
# robocopy /MIR keeps files that differ only by our edits (it will NOT revert
# them), so explicitly re-copy the three files we patch from the untouched
# shared source. This makes every subsequent patch deterministic and self-
# correcting across re-runs (no stale/broken ohos block can persist).
foreach ($rel in @('Makefile.libretro', 'scripts/toolchain.lua', 'makefile')) {
  $srcF = Join-Path $MameSrc $rel
  $dstF = Join-Path $WorkSrc $rel
  if (Test-Path -LiteralPath $srcF) {
    Copy-Item -LiteralPath $srcF -Destination $dstF -Force
  }
}

# ---- 3. OHOS clang wrapper scripts (LF, inside the worktree) --------------
# LF line endings + valid content are written here; the +x bit is applied via
# WSL below (after $tcWsl is known), because drvfs with per-drive metadata does
# NOT auto-mark freshly written files executable (else make fails "Permission denied").
# These wrappers are private to this build.
New-Item -ItemType Directory -Force -Path $OhosTc | Out-Null

function Write-LfFile {
  param([string]$Path, [string]$Content)
  # Build with LF only and force LF on write (WriteAllText honours the string's
  # embedded 0x0A; the -replace guards against any CRLF that crept in).
  $Content = $Content -replace "`r`n", "`n" -replace "`r", "`n"
  [System.IO.File]::WriteAllText($Path, $Content)
}

# clang wrapper bodies: drop -fuse-ld=lld for bare version/help queries so the
# build's compiler-version probe (gcc -dumpfullversion / -v) succeeds.
$clangWsl      = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/clang.exe"
$clangppWsl    = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/clang++.exe"
$llvmArWsl     = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/llvm-ar.exe"
$llvmRanlibWsl = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/llvm-ranlib.exe"
$llvmStripWsl  = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/llvm-strip.exe"
$llvmNmWsl     = "/mnt/d/HuaWei/Sdk/$OhosVersion/native/llvm/bin/llvm-nm.exe"

# WSL interop does NOT rewrite absolute /mnt/<drive>/ paths that appear inside
# argv entries (e.g. -I/-L/-include/-MF) for the Windows clang; it only
# translates the cwd and the primary input. So every wrapper must rewrite
# /mnt/<drive>/... to <drive>:/... before exec'ing the Windows tool.
$gccBody = @'
#!/bin/bash
ARGS="--target=aarch64-linux-ohos --sysroot=__SYSROOT__"
# Rewrite /mnt/<drive>/... -> <drive>:/... for all path args (see note above),
# and remember the ORIGINAL -MF/-o values (pre-translation, i.e. /mnt/... form)
# so we can post-fix the generated .d dependency file afterwards.
args=()
orig_dep=""
orig_out=""
prev_mf=0
prev_o=0
for a in "$@"; do
  if [ "$prev_mf" = 1 ]; then orig_dep="$a"; prev_mf=0; fi
  if [ "$prev_o"  = 1 ]; then orig_out="$a"; prev_o=0;  fi
  case "$a" in
    -MF) prev_mf=1 ;;
    -o)  prev_o=1  ;;
  esac
  # Translate any /mnt/<drive>/... -> <drive>:/... (combined flags too).
  while [[ "$a" =~ (/mnt/([a-zA-Z])/) ]]; do
    a="${a//${BASH_REMATCH[1]}/${BASH_REMATCH[2]}:/}"
  done
  args+=("$a")
done
# Work out the dependency file clang will write, so we can fix it for make.
depfile="$orig_dep"
if [ -z "$depfile" ] && { [[ " ${args[*]} " == *" -MMD "* ]] || [[ " ${args[*]} " == *" -MD "* ]] || [[ " ${args[*]} " == *" -MP "* ]]; } && [ -n "$orig_out" ]; then
  depfile="${orig_out%.o}.d"
fi
if echo " $* " | grep -qE ' -dump(full)?version '; then
  # This OHOS clang errors on a bare -dumpfullversion ("no input files"), so
  # report the version number derived from --version. MAME parses GCC_VERSION
  # as X.Y.Z and requires >= 11.
  __CLANG__ --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
  exit 0
fi
if echo " ${args[*]} " | grep -qE ' -v | --version | -print-'; then
  exec __CLANG__ $ARGS "${args[@]}"
fi
__CLANG__ $ARGS -fuse-ld=lld "${args[@]}"
rc=$?
# GNU make (running under Linux/WSL) cannot parse drive-letter paths with
# colons, but clang wrote the resolved d:/... include paths into the .d.
# Rewrite d:/... -> /mnt/d/... so make can read the dependency file.  clang
# still located the headers via d:/..., so this only affects the .d text.
if [ -n "$depfile" ] && [ -f "$depfile" ]; then
  sed -i 's!\([dD]\):/!/mnt/d/!g' "$depfile"
fi
exit $rc
'@

$toolBody = @'
#!/bin/bash
# Translate /mnt/<drive>/... -> <drive>:/... for the Windows LLVM tool.
args=()
for a in "$@"; do
  # Translate any /mnt/<drive>/... -> <drive>:/... (handles combined flags like
  # -I/mnt/d/... as well as separate tokens). Pure bash, no per-arg fork.
  while [[ "$a" =~ (/mnt/([a-zA-Z])/) ]]; do
    a="${a//${BASH_REMATCH[1]}/${BASH_REMATCH[2]}:/}"
  done
  args+=("$a")
done
exec __TOOL__ "${args[@]}"
'@

$wrappers = @{
  'ohos-arm64-gcc'   = $gccBody -replace '__SYSROOT__', $sysrootWin -replace '__CLANG__', $clangWsl
  'ohos-arm64-g++'   = $gccBody -replace '__SYSROOT__', $sysrootWin -replace '__CLANG__', $clangppWsl
  'ohos-arm64-ld'    = $gccBody -replace '__SYSROOT__', $sysrootWin -replace '__CLANG__', $clangWsl
  'ohos-arm64-ar'    = $toolBody -replace '__TOOL__', $llvmArWsl
  'ohos-arm64-ranlib'= $toolBody -replace '__TOOL__', $llvmRanlibWsl
  'ohos-arm64-strip' = $toolBody -replace '__TOOL__', $llvmStripWsl
  'ohos-arm64-nm'    = $toolBody -replace '__TOOL__', $llvmNmWsl
}
foreach ($kv in $wrappers.GetEnumerator()) {
  Write-LfFile -Path (Join-Path $OhosTc $kv.Key) -Content $kv.Value
}
Write-Host "[tc] wrote $(($wrappers.Keys.Count)) OHOS clang wrappers to $OhosTc" -ForegroundColor Cyan

# ---- 4. idempotent Makefile.libretro ohos-arm64 block ---------------------
# A clean base is guaranteed by the force-copy in Step 2.5, so this always
# re-applies deterministically (robocopy /MIR will not revert prior edits).
$mkLibretro = Join-Path $WorkSrc 'Makefile.libretro'
$mkContent  = [System.IO.File]::ReadAllText($mkLibretro)
if ($mkContent -notmatch 'TARGETOS=ohos-arm64') {
  Write-Host '==> patching Makefile.libretro with ohos-arm64 platform block' -ForegroundColor Cyan
  $tab = [char]9
  $block = @"
# ---------------------------------------------------------------------------
# OHOS (HarmonyOS) arm64 -- reuse the linux targetos but drive the build with
# the OHOS SDK clang (aarch64-linux-ohos). Toolchain wrappers live in ohos-tc/
# and are referenced via OVERRIDE_CC/CXX/AR. The shared build/mame-src is never
# touched: this block only exists inside the isolated build/mame-ohos-src copy.
# ---------------------------------------------------------------------------
ifeq ($(platform),ohos-arm64)
#__TAB__#PLATFLAGS += TARGETOS=ohos-arm64 gcc=ohos-arm64 PLATFORM=arm64 ARCHITECTURE=
#__TAB__#PLATFLAGS += OVERRIDE_CC=ohos-arm64-gcc OVERRIDE_CXX=ohos-arm64-g++ AR=ohos-arm64-ar RANLIB=ohos-arm64-ranlib
#__TAB__#PLATFLAGS += STRIP=ohos-arm64-strip NM=ohos-arm64-nm
#__TAB__#LIBRETRO_CPU :=
#__TAB__#LIBRETRO_OS :=
#__TAB__#PTR64 :=
endif

"@
  $block = $block -replace '#__TAB__#', $tab
  # Insert right before the ANDROID_NDK_HOME sanity check.
  $mkContent = $mkContent -replace 'ifneq \(\$\(ANDROID_NDK_HOME\),\)', ($block + 'ifneq ($(ANDROID_NDK_HOME),)')
  [System.IO.File]::WriteAllText($mkLibretro, $mkContent)
} else {
  Write-Host '==> Makefile.libretro already has ohos-arm64 block' -ForegroundColor Cyan
}

# ---- 4b. idempotent scripts/toolchain.lua ohos-arm64 flavor ---------------
$tcLua = Join-Path $WorkSrc 'scripts\toolchain.lua'
$tcLuaContent = [System.IO.File]::ReadAllText($tcLua)
if ($tcLuaContent -notmatch 'ohos-arm64') {
  Write-Host '==> patching scripts/toolchain.lua for ohos-arm64 flavor' -ForegroundColor Cyan
  $tab = [char]9
  # 1) allow the --gcc=ohos-arm64 option in the allowed list
  $tcLuaContent = $tcLuaContent.Replace('{ "android-arm64", "Android - ARM64" },',
    '{ "android-arm64", "Android - ARM64" },' + [Environment]::NewLine + '{ "ohos-arm64",    "OHOS (HarmonyOS) - ARM64" },')
  # 2) add the handling branch inside the gmake/ninja block (before vs2022)
  $ohosBranch = 'if "ohos-arm64" == _OPTIONS["gcc"] then' + [Environment]::NewLine +
    "$tab" + 'premake.gcc.cc   = "ohos-arm64-gcc"' + [Environment]::NewLine +
    "$tab" + 'premake.gcc.cxx  = "ohos-arm64-g++"' + [Environment]::NewLine +
    "$tab" + 'premake.gcc.ar   = "ohos-arm64-ar"' + [Environment]::NewLine +
    "$tab" + 'premake.gcc.llvm = true' + [Environment]::NewLine +
    "$tab" + 'location (_buildDir .. "projects/" .. _subDir .. "/".. _ACTION .. "-ohos-arm64")' + [Environment]::NewLine +
    "$tab" + 'end' + [Environment]::NewLine
  $anchor = [Environment]::NewLine + 'end' + [Environment]::NewLine + 'elseif _ACTION == "vs2022" then'
  $tcLuaContent = $tcLuaContent.Replace($anchor, ($ohosBranch + 'end' + [Environment]::NewLine + 'elseif _ACTION == "vs2022" then'))
  [System.IO.File]::WriteAllText($tcLua, $tcLuaContent)
} else {
  Write-Host '==> scripts/toolchain.lua already has ohos-arm64 flavor' -ForegroundColor Cyan
}

# ---- 4c. idempotent makefile ohos-arm64 target -----------------------------
$mkMain = Join-Path $WorkSrc 'makefile'
$mkMainContent = [System.IO.File]::ReadAllText($mkMain)
if ($mkMainContent -notmatch 'ohos-arm64/Makefile') {
  Write-Host '==> patching makefile with ohos-arm64 target' -ForegroundColor Cyan
  $tab = [char]9
  $block = @"
#-------------------------------------------------
# ohos-arm64 (HarmonyOS aarch64, OHOS SDK clang)
#-------------------------------------------------

ifeq ($(OSD), retro)
# Reuse the libretro/retro OSD. targetos=linux is forced AFTER $(TARGET_PARAMS)
# (which would otherwise pass --targetos=ohos-arm64). The gcc flavor ohos-arm64
# is registered in scripts/toolchain.lua and maps to the ohos-tc/ wrappers.
$(PROJECTDIR)/$(MAKETYPE)-ohos-arm64/Makefile: makefile $(SCRIPTS) $(GENIE)
#__TAB__#$(SILENT) $(GENIE) $(PARAMS) $(TARGET_PARAMS) --gcc=ohos-arm64 --gcc_version=$(GCC_VERSION) --osd=retro --targetos=linux --PLATFORM=arm64 --NO_USE_MIDI=1 --NO_OPENGL=1 --USE_QTDEBUG=0 --DONT_USE_NETWORK=1 --NOASM=1 $(MAKETYPE)

.PHONY: ohos-arm64
ohos-arm64: generate $(PROJECTDIR)/$(MAKETYPE)-ohos-arm64/Makefile
#__TAB__#$(SILENT) $(MAKE) $(MAKEPARAMS) -C $(PROJECTDIR)/$(MAKETYPE)-ohos-arm64 config=$(CONFIG) precompile
#__TAB__#$(SILENT) $(MAKE) $(MAKEPARAMS) -C $(PROJECTDIR)/$(MAKETYPE)-ohos-arm64 config=$(CONFIG)
endif # ifdef RETRO

"@
  $block = $block -replace '#__TAB__#', $tab
  # Insert right before the asmjs / Emscripten section.
  $asmAnchor = '#-------------------------------------------------' + [Environment]::NewLine + '# asmjs / Emscripten' + [Environment]::NewLine + '#-------------------------------------------------'
  $mkMainContent = $mkMainContent.Replace($asmAnchor, ($block + $asmAnchor))
  [System.IO.File]::WriteAllText($mkMain, $mkMainContent)
} else {
  Write-Host '==> makefile already has ohos-arm64 target' -ForegroundColor Cyan
}

# ---- 5. paths -------------------------------------------------------------
function ConvertTo-WslPath {
  param([Parameter(Mandatory = $true)][string]$WindowsPath)
  $full = (Resolve-Path -LiteralPath $WindowsPath).Path
  $drive = $full.Substring(0, 1).ToLower()
  $rest  = $full.Substring(2).Replace('\', '/')
  return "/mnt/$drive$rest"
}
$workWsl = ConvertTo-WslPath $WorkSrc
$tcWsl   = "$workWsl/ohos-tc"
# Freshly written wrappers are not auto-executable on a metadata-enabled drvfs
# mount; force +x so make can invoke them (else "ohos-arm64-g++: Permission denied").
& wsl.exe -e bash -lc "chmod +x $tcWsl/ohos-arm64-*"
$logWsl  = "$workWsl/build.log"

$destDir  = Join-Path $Root 'cores\ohos\build'
$destFile = Join-Path $destDir 'libgs_mame.so'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

if ($Jobs -le 0) {
  $cores = (& wsl.exe -e bash -lc 'nproc').Trim()
  if ($cores -notmatch '^\d+$') { $cores = 4 }
  $Jobs = [int]$cores
}

# ---- 6. build (inside WSL, source on /mnt, Windows clang via interop) ------
$subArg = if ($Subtarget) { "SUBTARGET=$Subtarget " } else { "" }
Write-Host "==> make -f Makefile.libretro platform=ohos-arm64 ${subArg}-j $Jobs (this takes hours)" -ForegroundColor Cyan
# 'set -o pipefail' so a failing make is detected through the tee|tail pipeline.
$buildCmd = "set -o pipefail; export PATH=${tcWsl}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; " +
            "unset ANDROID_NDK_HOME ANDROID_NDK_ROOT; " +
            "cd '$workWsl'; " +
            "make -f Makefile.libretro platform=ohos-arm64 NOWERROR=1 ${subArg}-j$Jobs 2>&1 | tee $logWsl | tail -50"
Invoke-Wsl $buildCmd

# ---- 7. locate and install the produced core -------------------------------
Write-Host '==> locating built libretro core' -ForegroundColor Cyan
$so = (& wsl.exe -e bash -lc "find '$workWsl' -name '*libretro*.so' -type f -printf '%T@ %p`n' | sort -rn | head -5 | cut -d' ' -f2-").Trim()
if ([string]::IsNullOrWhiteSpace($so)) {
  throw "Build finished but no '*libretro*.so' was found under $workWsl. Inspect $logWsl."
}
$soFirst = ($so -split "`n")[0].Trim()
Write-Host "[build] produced: $soFirst" -ForegroundColor Green

# strip debug symbols (via the OHOS llvm-strip wrapper, on PATH in WSL)
Invoke-Wsl "export PATH=${tcWsl}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ohos-arm64-strip --strip-unneeded '$soFirst' || true"

$soWin = $soFirst.Replace('/mnt/', (($workWsl.Substring(0, 6) -replace '/mnt/', '') ) )  # fallback; prefer Resolve-Path
# Re-derive a clean Windows path from the WSL path.
$soWin = 'D:' + $soFirst.Substring(6).Replace('/', '\')
if (-not (Test-Path -LiteralPath $soWin)) { throw "Stripped .so not found at $soWin" }
Copy-Item -LiteralPath $soWin -Destination $destFile -Force

# ---- 8. verify -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $destFile)) { throw "Install failed: $destFile not created" }
$len = [math]::Round((Get-Item -LiteralPath $destFile).Length / 1MB, 1)
Write-Host "==> installed libgs_mame.so ($len MB) -> $destFile" -ForegroundColor Green
Write-Host ''
Write-Host 'Notes:' -ForegroundColor Yellow
Write-Host '  * Source isolation: build/mame-src was NOT modified; changes live in build/mame-ohos-src.'
Write-Host '  * WSL hygiene: nothing was written into WSL home or ~/mame-build.'
Write-Host '  * Next: wire PlatformKind.mame core id + add OSS attribution (see build-mame.ps1 notes).'
