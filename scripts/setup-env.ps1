#requires -Version 5.1
<#
  GamePouch (趣玩匣) dev environment setup (zero system pollution, everything on D:).
  The shared toolchain (android-sdk / flutter / flutter_ohos / caches / jdk17) is
  reused from the sibling MyLangLean project via junctions, so nothing is
  downloaded twice. JDK 21 is materialised as a REAL directory under .tools
  (NOT a junction): Gradle 9.8 + JDK17 has a cold Kotlin-DSL regression on this
  host, and the JDK21 source used to live in a sibling project that has since
  been removed - the toolchain must stay self-contained.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\setup-env.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup-env.ps1 -SharedTools D:\path\to\.tools
  Idempotent: safe to re-run.
  Note: ASCII-only on purpose (Windows PowerShell 5.1 script encoding safety).
#>
[CmdletBinding()]
param(
  # Repo root. Leave empty to auto-detect (see Resolve-RepoRoot below); pass
  # -Root explicitly to override.
  [string]$Root = '',
  [string]$SharedTools = '',
  [string]$Jdk21Source = ''
)
$ErrorActionPreference = 'Stop'

# Walk up from $start until a directory containing a repo marker is found.
function Find-RepoRoot($start) {
  if (-not $start) { return $null }
  try { $cur = (Resolve-Path $start).Path } catch { return $null }
  for ($i = 0; $i -lt 6 -and $cur; $i++) {
    if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'app\pubspec.yaml'))) {
      return $cur
    }
    $parent = Split-Path -Parent $cur
    if (-not $parent -or $parent -eq $cur) { break }
    $cur = $parent
  }
  return $null
}

# $PSScriptRoot / $MyInvocation are NOT reliable across hosts (some wrappers set
# $PSScriptRoot to the caller's cwd, others leave $MyInvocation.MyCommand.Path
# unset), so probe every candidate and walk up to a real repo marker.
function Resolve-RepoRoot {
  $starts = @()
  if ($PSScriptRoot) { $starts += $PSScriptRoot }
  if ($MyInvocation.MyCommand.Path) { $starts += (Split-Path -Parent $MyInvocation.MyCommand.Path) }
  if ($PWD) { $starts += $PWD.Path }
  foreach ($s in $starts) {
    $r = Find-RepoRoot $s
    if ($r) { return $r }
  }
  throw "Cannot locate the GamePouch repo root from PSScriptRoot='$PSScriptRoot', " +
        "MyInvocation='$($MyInvocation.MyCommand.Path)', PWD='$PWD'. Pass -Root explicitly."
}

if (-not $Root) { $Root = Resolve-RepoRoot }
$Root = (Resolve-Path $Root).Path
$Tools = Join-Path $Root '.tools'
New-Item -ItemType Directory -Force $Tools | Out-Null

function Write-Step($m) { Write-Host "`n========== $m ==========" -ForegroundColor Cyan }

function Link-Or-Reuse($name, $target) {
  $dst = Join-Path $Tools $name
  if (Test-Path $dst) { Write-Host "exists: .tools\$name"; return }
  $src = Join-Path $target $name
  if (Test-Path $src) {
    New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
    Write-Host "junction: .tools\$name -> $src" -ForegroundColor Green
  }
  else { Write-Warning "missing in shared toolchain: $src" }
}

# ---------- 0. locate shared toolchain ----------
if (-not $SharedTools) {
  $cand = Join-Path (Split-Path $Root -Parent) 'MyLangLean\.tools'
  if (Test-Path $cand) { $SharedTools = $cand }
}
if (-not $SharedTools -or -not (Test-Path $SharedTools)) {
  throw "SharedTools not found: $SharedTools (pass -SharedTools explicitly)"
}
Write-Step "Reuse shared toolchain: $SharedTools"
foreach ($n in 'jdk17', 'android-sdk', 'flutter', 'flutter_ohos', 'caches') {
  Link-Or-Reuse $n $SharedTools
}

# ---------- 1. JDK 21 (Gradle 9.8.0 cold Kotlin-DSL friendly) ----------
# Gradle 9.3.1 + JDK17 has a cold Kotlin-DSL script-codegen regression on this
# host (1-arg script ctor -> NoSuchMethodError). Gradle 9.8.0 + JDK21 is clean.
#
# JDK21 is a REAL copy under .tools (never a junction): the historical source
# lived in a sibling project that has been removed, so the toolchain must not
# depend on anything outside this repo. Candidates are probed in order and the
# first one with a working bin\java.exe wins:
#   1) -Jdk21Source (explicit)
#   2) .tools\jdk21 itself (already provisioned)
#   3) Android Studio's bundled JBR (21.x on any recent AS install)
#   4) JAVA_HOME_21 / JAVA21_HOME env vars
$jdk21 = Join-Path $Tools 'jdk21'
if (-not (Test-Path (Join-Path $jdk21 'bin\java.exe'))) {
  $cands = @()
  if ($Jdk21Source) { $cands += $Jdk21Source }
  foreach ($p in @(
      'D:\Program Files\Android\Android Studio\jbr',
      'C:\Program Files\Android\Android Studio\jbr',
      "${env:JAVA_HOME_21}",
      "${env:JAVA21_HOME}"
    )) {
    if ($p) { $cands += $p }
  }
  $found = $null
  foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c 'bin\java.exe'))) { $found = $c; break }
  }
  if ($found) {
    New-Item -ItemType Directory -Force $jdk21 | Out-Null
    robocopy.exe $found $jdk21 /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) {
      Write-Warning "robocopy JDK21 failed (exit $LASTEXITCODE) from $found"
    }
    else {
      Write-Host "jdk21 provisioned (real copy) <- $found" -ForegroundColor Green
    }
  }
  else {
    Write-Warning 'JDK21 not found; falling back to JDK17. Gradle Kotlin DSL may fail cold.'
  }
}

# ---------- 2. verify ----------
Write-Step 'Verify'
# java -version writes to stderr; keep ErrorActionPreference out of the way.
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$sdk = Join-Path $Tools 'android-sdk'
$flt = Join-Path $Tools 'flutter'
foreach ($p in @('jdk21', 'jdk17')) {
  $java = Join-Path (Join-Path $Tools $p) 'bin\java.exe'
  if (Test-Path $java) { cmd /c "`"$java`" -version 2>&1" | Select-Object -First 1 }
}
$adb = Join-Path $sdk 'platform-tools\adb.exe'
if (Test-Path $adb) { cmd /c "`"$adb`" version 2>&1" | Select-Object -First 1 }
$fbat = Join-Path $flt 'bin\flutter.bat'
if (Test-Path $fbat) { cmd /c "`"$fbat`" --version 2>&1" | Select-Object -First 1 }
$ErrorActionPreference = $oldEap
Write-Host "`n[DONE] In every new terminal run first: . .\scripts\use-env.ps1" -ForegroundColor Green
