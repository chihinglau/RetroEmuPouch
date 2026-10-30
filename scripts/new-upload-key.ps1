<#
  Generate a DEDICATED upload keystore for Google Play App Signing.

  IMPORTANT: do NOT use the app's release keystore (keystore.properties) as the
  Play upload key. Play App Signing keeps the real app-signing key on Google's
  servers; you only ever hand Play the *upload* certificate. Generating a
  separate upload key limits blast radius if it ever leaks.

  Steps:
    1. Run this script to create upload-keystore.jks + print its cert fingerprints.
    2. In Play Console → App signing → "Upload a new app signing key", paste the
       upload certificate (or the SHA1/MD5 shown here).
    3. Build the AAB with scripts/build-apk.ps1 -Flavor store -BuildAab and upload it.

  The generated keystore lives at the repo root by default — add it to
  .gitignore and NEVER commit it.
#>
param(
  [string]$Alias = 'upload',
  [string]$StorePass = 'android',
  [string]$KeyPass = 'android',
  [string]$Validity = '10000',
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Tools = Join-Path $Root '.tools'
$jdk = Join-Path $Tools 'jdk21'
if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { $jdk = Join-Path $Tools 'jdk17' }
$keytool = Join-Path $jdk 'bin\keytool.exe'
if (-not (Test-Path $keytool)) { throw "keytool not found under $jdk" }

if ($OutFile -eq '') { $OutFile = Join-Path $Root 'upload-keystore.jks' }
if (Test-Path $OutFile) { throw "Output already exists: $OutFile (refusing to overwrite)" }

& $keytool -genkeypair -v `
  -keystore $OutFile -alias $Alias `
  -keyalg RSA -keysize 2048 -validity $Validity `
  -storepass $StorePass -keypass $KeyPass `
  -dname "CN=GamePouch Upload, OU=GamePouch, O=GamePouch, L=Unknown, ST=Unknown, C=CN"
if ($LASTEXITCODE -ne 0) { throw "keytool failed (exit $LASTEXITCODE)" }

Write-Host "Generated upload keystore: $OutFile" -ForegroundColor Green
Write-Host "Upload certificate fingerprints (paste into Play Console):" -ForegroundColor Cyan
& $keytool -list -v -keystore $OutFile -alias $Alias -storepass $StorePass 2>&1 |
  ForEach-Object { "$_" } | Select-String -Pattern 'Alias|MD5|SHA1|SHA256|Valid from'
Write-Host "Next: enroll this upload cert in Play Console (Play App Signing)." -ForegroundColor Yellow
Write-Host "REMINDER: add '$OutFile' to .gitignore and never commit it." -ForegroundColor Yellow
